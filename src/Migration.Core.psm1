Set-StrictMode -Version 2
$ErrorActionPreference='Stop'
if(-not ('ChatGPTtMigration.Engine' -as [type])){Add-Type -Path (Join-Path $PSScriptRoot 'Native.cs')}
$script:Tracked=@{}
function Get-Value($Object,[string]$Name,$Default=$null){
 if($null -eq $Object){return $Default}
 if($Object -is [Collections.IDictionary]){if($Object.Contains($Name)){return $Object[$Name]};return $Default}
 $p=$Object.PSObject.Properties[$Name];if($p){return $p.Value};return $Default
}
function Save-Json([string]$Path,$Object){[ChatGPTtMigration.Engine]::AtomicWrite($Path,($Object|ConvertTo-Json -Depth 16))}
function Read-Json([string]$Path){Get-Content -LiteralPath $Path -Raw -Encoding UTF8|ConvertFrom-Json}
function Get-StateRoot {Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'ChatGPTtMigration'}
function Set-PrivateDirectory([string]$Path,[string]$ReadPermissionsFrom=''){
 if(-not [IO.Directory]::Exists($Path)){[IO.Directory]::CreateDirectory($Path)|Out-Null}
 if([ChatGPTtMigration.Engine]::IsLink($Path)){throw "目标目录不能是链接：$Path"}
 $acl=New-Object Security.AccessControl.DirectorySecurity;$acl.SetAccessRuleProtection($true,$false)
 foreach($id in @([Security.Principal.WindowsIdentity]::GetCurrent().User.Value,'S-1-5-18','S-1-5-32-544')){
  $sid=New-Object Security.Principal.SecurityIdentifier($id)
  $acl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule($sid,'FullControl','ContainerInherit,ObjectInherit','None','Allow')))|Out-Null
 }
 if($ReadPermissionsFrom -and (Test-Path -LiteralPath $ReadPermissionsFrom)){
  foreach($rule in (Get-Acl -LiteralPath $ReadPermissionsFrom).Access){
   if($rule.IdentityReference.Value -like '*\CodexSandboxUsers' -and $rule.AccessControlType -eq 'Allow'){
    $acl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule($rule.IdentityReference,'ReadAndExecute','ContainerInherit,ObjectInherit','None','Allow')))|Out-Null
   }
  }
 }
 [ChatGPTtMigration.Engine]::SetDacl($Path,$acl.GetSecurityDescriptorBinaryForm())
}
function Get-Catalog([switch]$IncludeMissing) {
 $profile=[Environment]::GetFolderPath('UserProfile');$local=[Environment]::GetFolderPath('LocalApplicationData')
 $roaming=[Environment]::GetFolderPath('ApplicationData');$documents=[Environment]::GetFolderPath('MyDocuments')
 $list=[Collections.Generic.List[object]]::new();$seen=@{}
 function Add-Candidate([string]$Id,[string]$Product,[string]$Name,[string]$Source,[string]$Suffix,[bool]$Default=$true){
  if(-not(Test-Path -LiteralPath $Source)){
   if($IncludeMissing){$list.Add([pscustomobject]@{Id=$Id;Product=$Product;Name=$Name;Source=[IO.Path]::GetFullPath($Source);Suffix=$Suffix;Default=$false;Linked=$false;Current='';Error='源目录不存在';Files=0;Bytes=[long]0})}
   return
  }
  try{
   $canonical=[ChatGPTtMigration.Engine]::Canonical($Source)
   if($seen.ContainsKey($canonical)){return};$seen[$canonical]=$true
   $item=Get-Item -LiteralPath $Source -Force
   $list.Add([pscustomobject]@{Id=$Id;Product=$Product;Name=$Name;Source=[IO.Path]::GetFullPath($Source);Suffix=$Suffix;Default=$Default;Linked=($item.LinkType -eq 'Junction');Current=$canonical;Error='';Files=0;Bytes=[long]0})
  }catch{
   $list.Add([pscustomobject]@{Id=$Id;Product=$Product;Name=$Name;Source=$Source;Suffix=$Suffix;Default=$false;Linked=$false;Current='';Error=$_.Exception.Message;Files=0;Bytes=[long]0})
  }
 }
 $packages=Join-Path $local 'Packages'
 if(Test-Path -LiteralPath $packages){
  foreach($package in @(Get-ChildItem -LiteralPath $packages -Directory -ErrorAction SilentlyContinue|Where-Object {$_.Name -match '^(OpenAI\.Codex|OpenAI\.ChatGPT|OpenAI\.ChatGPT-Desktop|.*ChatGPT-Desktop)_'})){
   foreach($profileName in @('Codex','ChatGPT')){
    Add-Candidate ('browser-'+$package.Name+'-'+$profileName) 'ChatGPT' ('内置浏览器数据（'+$profileName+'）') (Join-Path $package.FullName ('LocalCache\Roaming\'+$profileName)) 'BrowserData'
   }
   Add-Candidate ('logs-'+$package.Name) 'ChatGPT' '桌面应用日志' (Join-Path $package.FullName 'LocalCache\Local\Codex\Logs') 'Logs'
  }
 }
 Add-Candidate 'browser-fallback-codex' 'ChatGPT' '其他桌面浏览器数据' (Join-Path $roaming 'Codex') 'RoamingData'
 Add-Candidate 'browser-fallback-chatgpt' 'ChatGPT' 'ChatGPT 本地数据' (Join-Path $roaming 'ChatGPT') 'ChatGPTData'
 Add-Candidate 'logs-fallback' 'ChatGPT' '桌面应用日志' (Join-Path $local 'Codex\Logs') 'Logs'
 Add-Candidate 'chatgpt-documents' 'ChatGPT' 'ChatGPT 文档及输出' (Join-Path $documents 'ChatGPT') 'Documents'
 Add-Candidate 'codex-home' 'Codex' '会话、插件、配置及技能' (Join-Path $profile '.codex') 'Home'
 Add-Candidate 'codex-runtimes' 'Codex' '工具运行环境' (Join-Path $profile '.cache\codex-runtimes') 'Runtimes'
 Add-Candidate 'codex-localruntime' 'Codex' '后台运行组件' (Join-Path $local 'OpenAI\Codex') 'LocalRuntime'
 Add-Candidate 'codex-documents' 'Codex' '工作目录及输出' (Join-Path $documents 'Codex') 'Workspaces'
 Add-Candidate 'shared-skills' 'Codex' '共享技能（可选，含其他工具技能）' (Join-Path $profile '.agents\skills') 'SharedSkills' $false
 Add-Candidate 'chatcut-data' 'ChatCut' '项目、备份、预览及助手数据' (Join-Path $roaming 'ChatCut') 'Data'
 Add-Candidate 'chatcut-local' 'ChatCut' '字体等本地缓存' (Join-Path $local 'ChatCut') 'LocalData'
 Add-Candidate 'chatcut-updater' 'ChatCut' '更新安装包缓存' (Join-Path $local 'chatcut-desktop-updater') 'UpdateCache'
 @($list.ToArray())
}
function Get-EntryStats($Entry,[Action[string,int,int,string]]$Progress=$null){
 $snapshot=[ChatGPTtMigration.Engine]::Scan($Entry.Source,$Progress)
 $Entry.Files=$snapshot.Files.Length;$Entry.Bytes=$snapshot.Bytes;return $Entry
}
function Test-Under([string]$Path,[string]$Parent){
 $p=[ChatGPTtMigration.Engine]::Full($Path).TrimEnd('\');$q=[ChatGPTtMigration.Engine]::Full($Parent).TrimEnd('\')
 $p.Equals($q,[StringComparison]::OrdinalIgnoreCase) -or $p.StartsWith($q+'\',[StringComparison]::OrdinalIgnoreCase)
}
function Get-FreeBytes([string]$Path){(New-Object IO.DriveInfo([IO.Path]::GetPathRoot([IO.Path]::GetFullPath($Path)))).AvailableFreeSpace}
function Assert-LocalTarget([string]$Path){
 if($Path -notmatch '^[A-Za-z]:\\' -or $Path -match '^\\'){throw '目标必须是本地磁盘的绝对路径。'}
 $drive=New-Object IO.DriveInfo([IO.Path]::GetPathRoot($Path))
 if(-not $drive.IsReady -or $drive.DriveFormat -ne 'NTFS' -or $drive.DriveType-ne 'Fixed'){throw '目标盘必须是已就绪的固定 NTFS 本地磁盘。'}
}
function Get-Destination($Entry,[string]$TargetRoot){Join-Path (Join-Path ([IO.Path]::GetFullPath($TargetRoot)) $Entry.Product) $Entry.Suffix}
function New-Plan([object[]]$Entries,[string]$TargetRoot,[bool]$KeepBackup=$true,[bool]$StopHelpers=$true,[bool]$ManageServices=$true){
 Assert-LocalTarget $TargetRoot
 if(-not $Entries.Count){throw '请至少选择一个未迁移的目录。'}
 $destinations=@{};$total=[long]0;$planEntries=[Collections.Generic.List[object]]::new()
 foreach($entry in $Entries){
  if($entry.Error){throw $entry.Error};if($entry.Linked){throw ('已有目录链接，仅支持验证，不能重复迁移：'+$entry.Source)}
  $entry=Get-EntryStats $entry;$destination=Get-Destination $entry $TargetRoot
  if((Test-Under $destination $entry.Source) -or (Test-Under $entry.Source $destination)){throw '源目录和目标目录不能互相包含。'}
  foreach($other in $Entries){if(Test-Under $destination $other.Source){throw ('目标落在另一个待迁移源目录中：'+$destination)}}
  if($destinations.ContainsKey($destination)){throw ('目标重名，请分开处理不同版本：'+$destination)};$destinations[$destination]=$true
  if(Test-Path -LiteralPath $destination){
   if([ChatGPTtMigration.Engine]::IsLink($destination) -or [IO.Directory]::GetFileSystemEntries([ChatGPTtMigration.Engine]::Long($destination)).Length){throw ('目标目录非空或为链接，不会覆盖：'+$destination)}
  }
  $parent=[IO.Path]::GetDirectoryName($destination)
  while(-not(Test-Path -LiteralPath $parent)){$parent=[IO.Path]::GetDirectoryName($parent)}
  $resolvedParent=[ChatGPTtMigration.Engine]::Canonical($parent)
  foreach($other in $Entries){if(Test-Under $resolvedParent ([ChatGPTtMigration.Engine]::Canonical($other.Source))){throw '目标父目录通过链接指回了源目录。'}}
  $planEntries.Add([pscustomobject]@{Id=$entry.Id;Product=$entry.Product;Name=$entry.Name;Source=$entry.Source;Destination=$destination;Files=$entry.Files;Bytes=$entry.Bytes})
  $total+=$entry.Bytes
 }
 $reserve=[Math]::Max(64MB,[long]($total*.05));if((Get-FreeBytes $TargetRoot)-lt ($total+$reserve)){throw '目标磁盘空间不足，需预留校验和运行余量。'}
 [pscustomobject]@{Schema=1;Id=[guid]::NewGuid().ToString('N');Owner=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value;Created=(Get-Date).ToString('o');TargetRoot=[IO.Path]::GetFullPath($TargetRoot);KeepBackup=$KeepBackup;StopHelpers=$StopHelpers;ManageServices=$ManageServices;Bytes=$total;Entries=@($planEntries.ToArray())}
}
function Assert-Plan($Plan){
 if($Plan.Schema-ne 1 -or $Plan.Id-notmatch '^[0-9a-f]{32}$'){throw '计划格式不受支持。'}
 if($Plan.Owner-ne [Security.Principal.WindowsIdentity]::GetCurrent().User.Value){throw '计划属于其他 Windows 用户。'}
 Assert-LocalTarget $Plan.TargetRoot
 foreach($option in @('KeepBackup','StopHelpers','ManageServices')){if((Get-Value $Plan $option)-isnot [bool]){throw '计划选项类型错误。'}}
 $catalog=@(Get-Catalog -IncludeMissing)
 $seen=@{}
 foreach($entry in @($Plan.Entries)){
  $known=@($catalog|Where-Object {$_.Id-eq $entry.Id -and $_.Source-ieq $entry.Source})
  if($known.Count-ne 1){throw ('源目录不在当前用户支持清单中：'+$entry.Source)}
  if($entry.Product-ne $known[0].Product){throw '计划中的应用类型与支持清单不一致。'}
  if($seen.ContainsKey($entry.Id)){throw '计划含重复目录。'};$seen[$entry.Id]=$true
  if($entry.Destination-ine (Get-Destination $known[0] $Plan.TargetRoot)){throw '计划中的目标路径不符合目录映射。'}
  if((Test-Under $entry.Source $entry.Destination)-or (Test-Under $entry.Destination $entry.Source)){throw '计划含路径循环。'}
 }
}
function Get-ResourceLockPath([string]$Kind,[string]$Path){
 $key=$Kind+':'+[ChatGPTtMigration.Engine]::Full($Path).ToUpperInvariant();$sha=[Security.Cryptography.SHA256]::Create()
 try{$hash=([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($key)))).Replace('-','')}finally{$sha.Dispose()}
 Join-Path (Join-Path (Get-StateRoot) 'locks') ($hash+'.lock')
}
function New-Run($Plan){
 $root=Get-StateRoot;Set-PrivateDirectory $root
 $runs=Join-Path $root 'runs';if(-not(Test-Path -LiteralPath $runs)){[IO.Directory]::CreateDirectory($runs)|Out-Null}
 $run=Join-Path $runs $Plan.Id;if(Test-Path -LiteralPath $run){throw '任务目录已存在。'}
 Set-PrivateDirectory $run;Save-Json (Join-Path $run 'plan.json') $Plan
 $engine=Join-Path $run 'engine';[IO.Directory]::CreateDirectory($engine)|Out-Null
 foreach($file in @(Get-ChildItem -LiteralPath $PSScriptRoot -File|Where-Object {$_.Extension-in @('.ps1','.psm1','.cs')})){Copy-Item -LiteralPath $file.FullName -Destination (Join-Path $engine $file.Name)}
 Save-Json (Join-Path $run 'journal.json') ([pscustomobject]@{Schema=1;Id=$Plan.Id;Entries=@();Services=@();Recovered=$false})
 Save-Json (Join-Path $run 'status.json') @{State='prepared';Detail='计划已保存，尚未移动文件。';Entries=@();Errors=@();Time=(Get-Date).ToString('o');ProcessId=0;Mode='Migrate'}
 $run
}
function Get-BackupPath($Entry,[string]$JobId,[string]$Kind='old'){
 # Short sibling names avoid pushing otherwise valid source paths over legacy limits.
 $sha=[Security.Cryptography.SHA256]::Create()
 try{$tag=([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes([string]$Entry.Id)))).Replace('-','').Substring(0,8)}finally{$sha.Dispose()}
 Join-Path ([IO.Path]::GetDirectoryName($Entry.Source)) ('.cgptt-'+$Kind+'-'+$JobId.Substring(0,8)+'-'+$tag)
}
function Assert-OwnedSibling([string]$Path,$Entry,[string]$JobId,[string]$Kind='old'){
 $expected=Get-BackupPath $Entry $JobId $Kind
 if([ChatGPTtMigration.Engine]::Full($Path)-ine [ChatGPTtMigration.Engine]::Full($expected)){throw '副本路径校验失败。'}
 if([ChatGPTtMigration.Engine]::IsLink($Path)){throw '副本是链接，拒绝递归删除或移动。'}
 $parent=[ChatGPTtMigration.Engine]::Canonical([IO.Path]::GetDirectoryName($expected))
 if([ChatGPTtMigration.Engine]::Canonical($Path)-ine (Join-Path $parent ([IO.Path]::GetFileName($expected)))){throw '副本最终路径异常。'}
 $null=[ChatGPTtMigration.Engine]::Scan($Path,$null)
}
function Test-Link([string]$Source,[string]$Destination){
 if(-not(Test-Path -LiteralPath $Source)-or -not(Test-Path -LiteralPath $Destination)){return $false}
 $item=Get-Item -LiteralPath $Source -Force
 $item.LinkType-eq 'Junction' -and [ChatGPTtMigration.Engine]::Canonical($Source)-ieq [ChatGPTtMigration.Engine]::Canonical($Destination)
}
function Get-ProcessClassification($Process,[string[]]$Products,[long]$WindowHandle=0){
 $kind='';$canStop=$false
 if(($Products-contains 'ChatGPT'-or $Products-contains 'Codex')-and $Process.Name-match '^(ChatGPT|Codex)\.exe$'){$kind='应用或命令行进程'}
 if($Products-contains 'ChatCut' -and $Process.Name-ieq 'ChatCut.exe'){
  $kind='ChatCut 桌面或托盘进程'
  $exe=[string](Get-Value $Process 'ExecutablePath' '');$command=[string](Get-Value $Process 'CommandLine' '')
  if($exe-and [IO.Path]::GetFileName($exe)-ieq 'ChatCut.exe'){
   $expected=[IO.Path]::Combine([IO.Path]::GetDirectoryName($exe),'resources\app.asar\out\main\mcp\server.js')
   if($command.Replace('/','\').IndexOf($expected,[StringComparison]::OrdinalIgnoreCase)-ge 0 -and $WindowHandle-eq 0){$kind='ChatCut 无窗口插件连接服务';$canStop=$true}
  }
 }
 [pscustomobject]@{Kind=$kind;CanStop=$canStop}
}
function Get-AppProcesses([string[]]$Products){
 $snapshot=@(Get-CimInstance Win32_Process);$session=(Get-Process -Id $PID).SessionId;$owned=@{}
 foreach($p in $snapshot){
  if($p.SessionId-ne $session){continue}
  $window=[long]0
  if($p.Name-ieq 'ChatCut.exe'){try{$window=(Get-Process -Id $p.ProcessId -ErrorAction Stop).MainWindowHandle.ToInt64()}catch{continue}}
  $classification=Get-ProcessClassification $p $Products $window;$kind=$classification.Kind;$canStop=$classification.CanStop
  $key=[string]$p.ProcessId+'|'+[string]$p.CreationDate
  if($kind){$owned[[int]$p.ProcessId]=[pscustomobject]@{Process=$p;Kind=$kind;CanStop=$canStop}}
  elseif($script:Tracked.ContainsKey($key)){$owned[[int]$p.ProcessId]=[pscustomobject]@{Process=$p;Kind='应用辅助进程';CanStop=$false}}
 }
 $changed=$true
 while($changed){$changed=$false;foreach($p in $snapshot){if($p.SessionId-eq $session -and -not $owned.ContainsKey([int]$p.ProcessId)-and $owned.ContainsKey([int]$p.ParentProcessId)){$owned[[int]$p.ProcessId]=[pscustomobject]@{Process=$p;Kind='应用辅助进程';CanStop=$false};$changed=$true}}}
 foreach($value in $owned.Values){$p=$value.Process;$key=[string]$p.ProcessId+'|'+[string]$p.CreationDate;$script:Tracked[$key]=$true
  [pscustomobject]@{Id=[int]$p.ProcessId;Name=$p.Name;Path=$p.ExecutablePath;Kind=$value.Kind;CanStop=$value.CanStop;Creation=[string]$p.CreationDate;CommandLine=$p.CommandLine}
 }
}
function Stop-KnownHelper($Record){
 $p=Get-CimInstance Win32_Process -Filter ('ProcessId='+$Record.Id)
 if(-not $p){return}
 if([string]$p.CreationDate-ne $Record.Creation -or $p.ExecutablePath-ine $Record.Path -or -not (Get-ProcessClassification $p @('ChatCut') 0).CanStop){throw '辅助进程身份发生变化，拒绝终止。'}
 if((Get-Process -Id $p.ProcessId).MainWindowHandle-ne 0){throw '辅助进程出现了可见窗口，拒绝终止。'}
 Stop-Process -Id $p.ProcessId -ErrorAction Stop
}
function Register-IndependentTask([string]$Script,[string]$Arguments,[string]$WorkingDirectory,[string]$Name){
 if($Script.Contains('"')-or $WorkingDirectory.Contains('"')){throw '路径含无效引号。'}
 $scheduler=New-Object -ComObject Schedule.Service;$scheduler.Connect();$folder=$scheduler.GetFolder('\');$d=$scheduler.NewTask(0)
 $d.RegistrationInfo.Description='ChatGPT迁移助手：用户启动的一次性本地任务，无周期触发器。'
 $d.Settings.Enabled=$true;$d.Settings.AllowDemandStart=$true;$d.Settings.Hidden=$true;$d.Settings.DisallowStartIfOnBatteries=$false;$d.Settings.StopIfGoingOnBatteries=$false;$d.Settings.ExecutionTimeLimit='PT24H';$d.Settings.MultipleInstances=2
 $d.Principal.UserId=[Security.Principal.WindowsIdentity]::GetCurrent().Name;$d.Principal.LogonType=3
 $elevated=([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
 $d.Principal.RunLevel=$(if($elevated){1}else{0})
 $action=$d.Actions.Create(0);$action.Path=Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
 $action.Arguments='-NoProfile -NonInteractive -STA -ExecutionPolicy Bypass -WindowStyle Hidden -File "'+$Script+'" '+$Arguments;$action.WorkingDirectory=$WorkingDirectory
 $task=$folder.RegisterTaskDefinition($Name,$d,6,$d.Principal.UserId,$null,3);$instance=$task.Run($null)
 [pscustomobject]@{Task=$Name;ProcessId=$instance.EnginePID}
}
function Start-Run([string]$RunDirectory,[ValidateSet('Migrate','Rollback','Cleanup')][string]$Mode='Migrate'){
 $plan=Read-Json (Join-Path $RunDirectory 'plan.json');Assert-Plan $plan
 $status=Read-Json (Join-Path $RunDirectory 'status.json')
 if($status.State-notin @('prepared','complete','error','partial_error','cancelled')-and [int]$status.ProcessId-gt 0){
  $running=Get-Process -Id ([int]$status.ProcessId) -ErrorAction SilentlyContinue
  if($running-and $running.ProcessName-eq 'powershell'-and $running.StartTime-le ([datetimeoffset]::Parse($status.Time).LocalDateTime)){throw '任务仍在运行。请等待完成或在进度窗口安全停止，再进行其他操作。'}
 }
 $cancel=Join-Path $RunDirectory 'cancel.request';if(Test-Path -LiteralPath $cancel){Remove-Item -LiteralPath $cancel -Force}
 $engine=Join-Path $RunDirectory 'engine'
 $task=Register-IndependentTask (Join-Path $engine 'Worker.ps1') ('-RunDirectory "'+$RunDirectory+'" -Mode '+$Mode) $RunDirectory ('ChatGPTt-'+$plan.Id)
 $viewer=Register-IndependentTask (Join-Path $engine 'Progress.ps1') ('-RunDirectory "'+$RunDirectory+'"') $RunDirectory ('ChatGPTt-View-'+$plan.Id)
 $task
}
function Get-History {
 $root=Join-Path (Get-StateRoot) 'runs';if(-not(Test-Path -LiteralPath $root)){return}
 foreach($folder in @(Get-ChildItem -LiteralPath $root -Directory|Sort-Object LastWriteTime -Descending)){
  try{$plan=Read-Json (Join-Path $folder.FullName 'plan.json');$status=Read-Json (Join-Path $folder.FullName 'status.json');[pscustomobject]@{Directory=$folder.FullName;Plan=$plan;Status=$status}}catch{}
 }
}
Export-ModuleMember -Function *
