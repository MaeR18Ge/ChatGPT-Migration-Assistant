param([Parameter(Mandatory=$true)][string]$RunDirectory,[ValidateSet('Migrate','Rollback','Cleanup')][string]$Mode='Migrate')
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot 'Migration.Core.psm1') -Force
$expectedRuns=Join-Path (Get-StateRoot) 'runs'
$runName=[IO.Path]::GetFileName($RunDirectory.TrimEnd('\'))
if($runName-notmatch '^[0-9a-f]{32}$' -or [IO.Path]::GetDirectoryName([ChatGPTtMigration.Engine]::Full($RunDirectory))-ine [ChatGPTtMigration.Engine]::Full($expectedRuns)){throw '任务目录不在本用户运行记录目录中。'}
if([ChatGPTtMigration.Engine]::IsLink($RunDirectory)){throw '任务目录不能是链接。'}
Set-Location -LiteralPath $RunDirectory
$lock=$null
try{$lock=[IO.File]::Open((Join-Path $RunDirectory 'worker.lock'),'OpenOrCreate','ReadWrite','None')}catch{exit 2}
$script:Plan=$null;$script:Journal=$null;$script:Restore=[Collections.Generic.List[string]]::new()
$script:Errors=[Collections.Generic.List[object]]::new();$script:Current='';$script:Phase='prepared';$script:State='prepared'
$resourceLocks=[Collections.Generic.List[IO.FileStream]]::new()
$statusPath=Join-Path $RunDirectory 'status.json';$journalPath=Join-Path $RunDirectory 'journal.json';$cancelPath=Join-Path $RunDirectory 'cancel.request'
function Write-Journal {Save-Json $journalPath $script:Journal}
function Report([string]$State,[string]$Detail,[int]$Count=0,[int]$Total=0,[string]$File=''){
 $script:State=$State
 Save-Json $statusPath @{State=$State;Detail=$Detail;Time=(Get-Date).ToString('o');ProcessId=$PID;Mode=$Mode;Current=$script:Current;Count=$Count;Total=$Total;File=$File;Entries=@(Get-Value $script:Journal 'Entries' @());Errors=@($script:Errors.ToArray());KeepBackup=(Get-Value $script:Plan 'KeepBackup' $true)}
 if($State-ne $script:Phase -or $State-in @('error','directory_error','complete','cancelled')){((Get-Date).ToString('o')+' '+$State+' '+$Detail)|Add-Content -LiteralPath (Join-Path $RunDirectory 'events.log') -Encoding UTF8}
 $script:Phase=$State
}
function Check-Cancel {if(Test-Path -LiteralPath $cancelPath){throw [OperationCanceledException]::new('用户请求在安全点停止。')}}
$progress=[Action[string,int,int,string]]{param($phase,$count,$total,$file) Check-Cancel;Report $phase $script:Current $count $total $file}
function Ensure-Idle {
 $processes=@(Get-AppProcesses @($script:Plan.Entries|ForEach-Object {$_.Product}|Select-Object -Unique))
 if($processes.Count){throw ('应用在操作期间重新启动，当前目录原副本保留：'+(($processes|ForEach-Object {$_.Name+' #'+$_.Id})-join ', '))}
}
function Wait-Applications {
 $products=@($script:Plan.Entries|ForEach-Object {$_.Product}|Select-Object -Unique);$deadline=(Get-Date).AddHours(23)
 while($true){
  Check-Cancel;$processes=@(Get-AppProcesses $products)
  foreach($p in $processes){if($p.CanStop-and $script:Plan.StopHelpers){Report 'helper' ('临时关闭已识别的无窗口连接服务：'+$p.Name+' #'+$p.Id);Stop-KnownHelper $p}}
  $processes=@(Get-AppProcesses $products);if(-not $processes.Count){break}
  if((Get-Date)-gt $deadline){throw '等待应用退出已超时，请保存工作并完全退出应用后重试。'}
  Report 'waiting' (($processes|ForEach-Object {$_.Kind+'：'+$_.Name+' #'+$_.Id})-join "`r`n")
  Start-Sleep -Seconds 3
 }
 Report 'preparing' '应用已退出，等待文件写入结束。';Start-Sleep -Seconds 4;Ensure-Idle
}
function Restore-Services {
 foreach($name in @($script:Restore.ToArray())){
  Report 'restoring_service' ('恢复后台服务：'+$name)
  $service=Get-Service -Name $name -ErrorAction Stop
  if($service.Status-eq 'StopPending'){$service.WaitForStatus([ServiceProcess.ServiceControllerStatus]::Stopped,[TimeSpan]::FromSeconds(25))}
  $service.Refresh();if($service.Status-ne 'Running'){Start-Service -Name $name -ErrorAction Stop}
  $service.WaitForStatus([ServiceProcess.ServiceControllerStatus]::Running,[TimeSpan]::FromSeconds(25))
  $script:Restore.Remove($name)|Out-Null
  $script:Journal.Services=@($script:Restore.ToArray());Write-Journal
 }
}
function Release-KnownLocks {
 $services=@{}
 foreach($entry in @($script:Plan.Entries)){
  $root=$entry.Source;if(-not(Test-Path -LiteralPath $root)){if($Mode-eq 'Rollback'){$root=$entry.Destination}else{continue}}
  $snapshot=[ChatGPTtMigration.Engine]::Scan($root,$null)
  foreach($row in $snapshot.Files){
   if($row.Relative-notlike '*.guard'){continue}
   $guard=Join-Path $root $row.Relative
   foreach($owner in @([ChatGPTtMigration.Locks]::Query($guard))){
    if(-not $owner.Service -or $owner.Service-notmatch '^CodexSandboxService\.OpenAI\.(Codex|ChatGPT)(\.|$)'){throw ('存在不能自动释放的文件锁：'+$guard+'；进程 '+$owner.ProcessId+' '+$owner.Name)}
    if(-not $script:Plan.ManageServices){throw ('需临时停止服务 '+$owner.Service+'，请启用服务释放选项后重试。')}
    $services[$owner.Service]=$true
   }
  }
 }
 foreach($name in $services.Keys){
  [ChatGPTtMigration.Locks]::CheckServicePermission($name)
  $service=Get-Service -Name $name -ErrorAction Stop
  if($service.Status-ne 'Stopped'){
   # Record restoration intent BEFORE changing service state, for recovery after interruption.
   if(-not $script:Restore.Contains($name)){$script:Restore.Add($name)}
   $script:Journal.Services=@($script:Restore.ToArray());Write-Journal
   Report 'stopping_service' ('临时停止持锁服务，结束后自动恢复：'+$name)
   Stop-Service -Name $name -ErrorAction Stop
   $service.WaitForStatus([ServiceProcess.ServiceControllerStatus]::Stopped,[TimeSpan]::FromSeconds(25))
  }
 }
}
function Get-Record($Entry){
 $records=@($script:Journal.Entries|Where-Object {$_.Id-eq $Entry.Id})
 if($records.Count-gt 1){throw '重复的目录事务记录。'}
 if($records.Count){return $records[0]}
 $record=[pscustomobject]@{Id=$Entry.Id;Source=$Entry.Source;Destination=$Entry.Destination;Backup=(Get-BackupPath $Entry $script:Plan.Id);RestoreTemp=(Get-BackupPath $Entry $script:Plan.Id 'restore');Claimed=$false;Phase='new';Bytes=$Entry.Bytes;Verified=$false;BackupRemoved=$false;Rollback=$false;RollbackVerified=$false;IncompleteCopies=@()}
 $script:Journal.Entries=@($script:Journal.Entries)+@($record);Write-Journal;return $record
}
function Assert-Record($Entry,$Record){
 if($Record.Source-ine $Entry.Source-or $Record.Destination-ine $Entry.Destination-or $Record.Backup-ine (Get-BackupPath $Entry $script:Plan.Id)-or $Record.RestoreTemp-ine (Get-BackupPath $Entry $script:Plan.Id 'restore')){throw '事务日志路径与计划不一致。'}
}
function Recover-Switch($Entry,$Record){
 Assert-Record $Entry $Record
 $sourceExists=Test-Path -LiteralPath $Entry.Source;$backupExists=Test-Path -LiteralPath $Record.Backup
 if(-not $sourceExists-and $backupExists){Assert-OwnedSibling $Record.Backup $Entry $script:Plan.Id;[ChatGPTtMigration.Engine]::MoveDirectory($Record.Backup,$Entry.Source);$Record.Phase='recovered';Write-Journal}
 elseif($sourceExists-and $backupExists-and (Test-Link $Entry.Source $Entry.Destination)-and -not $Record.Verified){
  Assert-OwnedSibling $Record.Backup $Entry $script:Plan.Id
  [IO.Directory]::Delete($Entry.Source);[ChatGPTtMigration.Engine]::MoveDirectory($Record.Backup,$Entry.Source);$Record.Phase='recovered';Write-Journal
 }
}
function Recover-MissingRoots {
 if(-not $script:Plan-or -not $script:Journal){return}
 foreach($entry in @($script:Plan.Entries)){
  if(Test-Path -LiteralPath $entry.Source){continue}
  $record=@($script:Journal.Entries|Where-Object {$_.Id-eq $entry.Id})|Select-Object -First 1
  if(-not $record){continue};Assert-Record $entry $record
  if($record.Phase-eq 'rollback_switching'-and $record.RollbackVerified-and (Test-Path -LiteralPath $record.RestoreTemp)){
   Assert-OwnedSibling $record.RestoreTemp $entry $script:Plan.Id 'restore';[ChatGPTtMigration.Engine]::MoveDirectory($record.RestoreTemp,$entry.Source);$record.Rollback=$true;$record.Phase='rolled_back';Write-Journal
  }elseif(Test-Path -LiteralPath $record.Backup){
   Assert-OwnedSibling $record.Backup $entry $script:Plan.Id;[ChatGPTtMigration.Engine]::MoveDirectory($record.Backup,$entry.Source);$record.Phase='recovered';Write-Journal
  }
 }
}
function Invoke-Entry($Entry){
 Check-Cancel;Ensure-Idle;$script:Current=$Entry.Source;$record=Get-Record $Entry;Assert-Record $Entry $record;Recover-Switch $Entry $record
 if(Test-Link $Entry.Source $Entry.Destination){
  if(-not $record.Verified){throw '已有链接缺少本任务的验证记录，拒绝重复操作。'}
  if(-not $script:Plan.KeepBackup-and (Test-Path -LiteralPath $record.Backup)){Assert-OwnedSibling $record.Backup $Entry $script:Plan.Id;[ChatGPTtMigration.Engine]::DeleteTree($record.Backup);$record.BackupRemoved=$true}
  $record.Phase='complete';Write-Journal;return
 }
 if([ChatGPTtMigration.Engine]::IsLink($Entry.Source)){throw '原目录已有其他链接，拒绝覆盖。'}
 if(-not $record.Claimed){
  if(Test-Path -LiteralPath $Entry.Destination){if([ChatGPTtMigration.Engine]::IsLink($Entry.Destination)-or [IO.Directory]::GetFileSystemEntries([ChatGPTtMigration.Engine]::Long($Entry.Destination)).Length){throw '目标已出现文件，不会覆盖。'}}
  $record.Claimed=$true;Write-Journal;Set-PrivateDirectory $Entry.Destination $Entry.Source
 }
 # On retry preserve an incomplete copy rather than mixing stale SQLite/temp files into a fresh copy.
 if([IO.Directory]::Exists($Entry.Destination)-and [IO.Directory]::GetFileSystemEntries([ChatGPTtMigration.Engine]::Long($Entry.Destination)).Length){
  $oldCopy=$Entry.Destination+'.incomplete-'+$script:Plan.Id.Substring(0,8)+'-'+[guid]::NewGuid().ToString('N').Substring(0,8)
  if([ChatGPTtMigration.Engine]::IsLink($Entry.Destination)){throw '目标副本变成了链接。'}
  [ChatGPTtMigration.Engine]::MoveDirectory($Entry.Destination,$oldCopy);$record.IncompleteCopies=@($record.IncompleteCopies)+@($oldCopy);Write-Journal;Set-PrivateDirectory $Entry.Destination $Entry.Source
 }
 $snapshot=[ChatGPTtMigration.Engine]::Scan($Entry.Source,$null)
 if((Get-FreeBytes $Entry.Destination)-lt ($snapshot.Bytes+64MB)){throw '目标剩余空间不足。'}
 $record.Phase='copying';Write-Journal;Report 'copying' $Entry.Name
 [ChatGPTtMigration.Engine]::Copy($Entry.Source,$Entry.Destination,$progress)
 $bytes=[ChatGPTtMigration.Engine]::Verify($Entry.Source,$Entry.Destination,$progress)
 Check-Cancel;Ensure-Idle
 if(Test-Path -LiteralPath $record.Backup){throw '原副本保留路径已存在，拒绝覆盖。'}
 Report 'switching' ('切换原路径：'+$Entry.Source);$record.Phase='switching';Write-Journal
 [ChatGPTtMigration.Engine]::MoveDirectory($Entry.Source,$record.Backup)
 try{
  New-Item -ItemType Junction -Path $Entry.Source -Target $Entry.Destination|Out-Null
  if(-not(Test-Link $Entry.Source $Entry.Destination)){throw '原路径链接验证失败。'}
  $null=[ChatGPTtMigration.Engine]::Verify($record.Backup,$Entry.Source,$progress)
 }catch{
  $reason=$_
  if(Test-Path -LiteralPath $Entry.Source){if(-not(Test-Link $Entry.Source $Entry.Destination)){throw '切换后原路径异常，原副本已保留。'};[IO.Directory]::Delete($Entry.Source)}
  [ChatGPTtMigration.Engine]::MoveDirectory($record.Backup,$Entry.Source);$record.Phase='recovered';Write-Journal;throw $reason
 }
 $record.Bytes=$bytes;$record.Verified=$true;$record.Phase='complete';Write-Journal
 if(-not $script:Plan.KeepBackup){Assert-OwnedSibling $record.Backup $Entry $script:Plan.Id;[ChatGPTtMigration.Engine]::DeleteTree($record.Backup);$record.BackupRemoved=$true;Write-Journal}
 Report 'entry_complete' ('已迁移：'+$Entry.Name)
}
function Invoke-Rollback($Entry){
 Check-Cancel;Ensure-Idle;$script:Current=$Entry.Source;$record=Get-Record $Entry;Assert-Record $Entry $record
 if($record.Rollback){return}
 if($record.Phase-eq 'rollback_switching' -and $record.RollbackVerified){
  if(-not(Test-Path -LiteralPath $Entry.Source)-and (Test-Path -LiteralPath $record.RestoreTemp)){Assert-OwnedSibling $record.RestoreTemp $Entry $script:Plan.Id 'restore';[ChatGPTtMigration.Engine]::MoveDirectory($record.RestoreTemp,$Entry.Source)}
  if((Test-Path -LiteralPath $Entry.Source)-and -not [ChatGPTtMigration.Engine]::IsLink($Entry.Source)){$null=[ChatGPTtMigration.Engine]::Verify($Entry.Destination,$Entry.Source,$progress);$record.Rollback=$true;$record.Phase='rolled_back';Write-Journal;return}
 }
 if(-not(Test-Link $Entry.Source $Entry.Destination)){
  if($record.Phase-in @('new','copying','recovered')){return};throw '原路径已被更改，不能自动回滚。'
 }
 $snapshot=[ChatGPTtMigration.Engine]::Scan($Entry.Destination,$null)
 if((Get-FreeBytes $Entry.Source)-lt ($snapshot.Bytes+64MB)){throw '原目录所在磁盘空间不足，无法复制最新数据回原位置。'}
 if(Test-Path -LiteralPath $record.RestoreTemp){throw '已有未完成的回滚副本，请保留并检查任务目录日志。'}
 Set-PrivateDirectory $record.RestoreTemp $Entry.Source
 Report 'copying' ('回滚时复制目标盘最新数据：'+$Entry.Name)
 [ChatGPTtMigration.Engine]::Copy($Entry.Destination,$record.RestoreTemp,$progress)
 $null=[ChatGPTtMigration.Engine]::Verify($Entry.Destination,$record.RestoreTemp,$progress)
 Check-Cancel;Ensure-Idle
 $record.RollbackVerified=$true;$record.Phase='rollback_switching';Write-Journal
 Report 'switching' ('恢复原目录：'+$Entry.Source)
 [IO.Directory]::Delete($Entry.Source) # Non-recursive: remove ONLY the junction, never target data.
 try{[ChatGPTtMigration.Engine]::MoveDirectory($record.RestoreTemp,$Entry.Source)}catch{New-Item -ItemType Junction -Path $Entry.Source -Target $Entry.Destination|Out-Null;throw}
 $record.Rollback=$true;$record.Phase='rolled_back';Write-Journal
}
function Invoke-Cleanup($Entry){
 $record=Get-Record $Entry;Assert-Record $Entry $record
 if($record.BackupRemoved-or -not(Test-Path -LiteralPath $record.Backup)){return}
 if(-not $record.Verified){throw '副本没有已校验的迁移记录，拒绝清理。'}
 if(-not $record.Rollback-and -not(Test-Link $Entry.Source $Entry.Destination)){throw '原路径链接异常，拒绝清理原副本。'}
 $script:Current=$Entry.Source;Report 'cleaning' ('清理已验证的原副本：'+$record.Backup)
 Assert-OwnedSibling $record.Backup $Entry $script:Plan.Id
 [ChatGPTtMigration.Engine]::DeleteTree($record.Backup);$record.BackupRemoved=$true;Write-Journal
}
try{
 $script:Plan=Read-Json (Join-Path $RunDirectory 'plan.json');Assert-Plan $script:Plan
 if($script:Plan.Id-ne $runName){throw '任务目录名称与计划 ID 不一致。'}
 $script:Journal=Read-Json $journalPath
 if($script:Journal.Id-ne $script:Plan.Id){throw '事务日志不匹配。'}
 Set-PrivateDirectory (Join-Path (Get-StateRoot) 'locks')
 $resourcePaths=@(foreach($entry in @($script:Plan.Entries)){Get-ResourceLockPath 'source' $entry.Source;Get-ResourceLockPath 'target' $entry.Destination})
 foreach($path in @($resourcePaths|Sort-Object -Unique)){
  try{$resourceLocks.Add([IO.File]::Open($path,'OpenOrCreate','ReadWrite','None'))}catch{throw '另一个任务正在使用相同的源或目标目录。请等待它完成。'}
 }
 foreach($service in @($script:Journal.Services)){
  if($service-notmatch '^CodexSandboxService\.OpenAI\.(Codex|ChatGPT)(\.|$)'){throw '日志含不受支持的服务名。'}
  $script:Restore.Add([string]$service)
 }
 if($Mode-ne 'Cleanup'-or $script:Restore.Count){Wait-Applications;Release-KnownLocks;Ensure-Idle;Recover-MissingRoots}
 foreach($entry in @($script:Plan.Entries)){
  try{
   if($Mode-eq 'Migrate'){Invoke-Entry $entry}
   elseif($Mode-eq 'Rollback'){Invoke-Rollback $entry}
   else{Invoke-Cleanup $entry}
  }catch{
   $reason=$_.Exception
   while($reason.InnerException){$reason=$reason.InnerException}
   if($reason-is [OperationCanceledException]){throw $reason}
   $script:Errors.Add(@{Id=$entry.Id;Source=$entry.Source;Error=$_.Exception.Message});Report 'directory_error' $_.Exception.Message
  }
 }
 Restore-Services
 if($script:Errors.Count){Report 'partial_error' '部分目录未完成，原副本已保留。可查看日志后重试。';exit 1}
 Report 'complete' $(if($Mode-eq 'Rollback'){'回滚完成，目标盘数据仍保留。'}elseif($Mode-eq 'Cleanup'){'已清理本任务的原副本。'}elseif($script:Plan.KeepBackup){'迁移完成，原副本保留。请验证应用正常后再清理。'}else{'迁移完成，已校验并清理源盘原副本。'})
}catch{
 $reason=$_.Exception;while($reason.InnerException){$reason=$reason.InnerException}
 if($reason-is [OperationCanceledException]){Report 'cancelled' '已在安全点停止，已完成目录保留，未切换目录的原文件未删除。'}else{Report 'error' $_.Exception.Message}
 exit 1
}finally{
 if($script:Restore.Count){try{Recover-MissingRoots;Restore-Services}catch{$script:Errors.Add(@{Error=('服务恢复失败：'+$_.Exception.Message)});Report 'error' '服务恢复失败，请查看错误详情。'}}
 if($lock){$lock.Dispose()}
 foreach($resourceLock in $resourceLocks){$resourceLock.Dispose()}
}
