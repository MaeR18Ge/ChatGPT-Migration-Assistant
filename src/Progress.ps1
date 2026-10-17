param([Parameter(Mandatory=$true)][string]$RunDirectory,[switch]$SelfTest)
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot 'Migration.Core.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'UI.psm1') -Force
Set-Location -LiteralPath ([IO.Path]::GetTempPath())
$plan=Read-Json (Join-Path $RunDirectory 'plan.json');Assert-Plan $plan
$form=New-UiForm 'ChatGPT迁移助手 - 迁移进度' 1040 720
$title=Add-UiLabel $form '数据迁移与恢复' 25 20 970 38;$title.Font=New-Object Drawing.Font('Microsoft YaHei UI',21,[Drawing.FontStyle]::Bold)
$stateLabel=Add-UiLabel $form '正在读取状态' 27 73 970 30;$stateLabel.Font=New-Object Drawing.Font('Microsoft YaHei UI',14,[Drawing.FontStyle]::Bold)
$summary=Add-UiLabel $form '' 27 112 970 25
$overall=New-Object Windows.Forms.ProgressBar;$overall.Location=New-Object Drawing.Point(27,143);$overall.Size=New-Object Drawing.Size(986,17);$overall.Maximum=[Math]::Max(1,@($plan.Entries).Count);$overall.Anchor='Top,Left,Right';$form.Controls.Add($overall)
$detail=Add-UiText $form 27 178 986 76 -Multi -ReadOnly;$detail.Anchor='Top,Left,Right'
$progress=New-Object Windows.Forms.ProgressBar;$progress.Location=New-Object Drawing.Point(27,267);$progress.Size=New-Object Drawing.Size(986,17);$progress.Anchor='Top,Left,Right';$form.Controls.Add($progress)
$fileLabel=Add-UiLabel $form '' 27 294 970 25
$grid=New-Object Windows.Forms.DataGridView;$grid.Location=New-Object Drawing.Point(27,330);$grid.Size=New-Object Drawing.Size(986,210);$grid.Anchor='Top,Bottom,Left,Right';$grid.ReadOnly=$true;$grid.AllowUserToAddRows=$false;$grid.AllowUserToDeleteRows=$false;$grid.RowHeadersVisible=$false;$grid.AutoSizeColumnsMode='Fill';$grid.SelectionMode='FullRowSelect';$grid.BackgroundColor=[Drawing.SystemColors]::Window
foreach($c in @(@('name','内容'),@('destination','目标目录'),@('phase','状态'))){$null=$grid.Columns.Add($c[0],$c[1])}
$grid.Columns[0].FillWeight=30;$grid.Columns[1].FillWeight=45;$grid.Columns[2].FillWeight=25
foreach($entry in @($plan.Entries)){$null=$grid.Rows.Add([object[]]@($entry.Name,$entry.Destination,'尚未处理'))}
Set-UiGridHeaders $grid;$form.Controls.Add($grid)
$backupLabel=Add-UiLabel $form '' 27 552 970 28;$backupLabel.Anchor='Bottom,Left,Right'
$updated=Add-UiLabel $form '' 27 582 970 24;$updated.Anchor='Bottom,Left,Right'
$note=Add-UiLabel $form '窗口独立运行；关闭窗口不会取消后台任务。请等操作完成再重新打开相关应用。' 27 611 970 30;$note.Anchor='Bottom,Left,Right'
$refresh=Add-UiButton $form '刷新' 27 663 80;$retry=Add-UiButton $form '继续 / 重试' 116 663 110;$cancel=Add-UiButton $form '安全停止' 235 663 100
$copy=Add-UiButton $form '复制状态' 344 663 105;$folder=Add-UiButton $form '打开日志目录' 458 663 130;$close=Add-UiButton $form '关闭窗口' 883 663 130
foreach($button in @($refresh,$retry,$cancel,$copy,$folder)){$button.Anchor='Bottom,Left'};$close.Anchor='Bottom,Right'
$script:last=$null;$script:raw='';$script:currentMode='Migrate'
function Update-View {
 try{$raw=Get-Content -LiteralPath (Join-Path $RunDirectory 'status.json') -Raw -Encoding UTF8;$status=$raw|ConvertFrom-Json;$script:last=$status;$script:raw=$raw}catch{$status=$script:last;if(-not $status){$detail.Text='状态正在更新，稍后自动重试。';return}}
 $script:currentMode=[string](Get-Value $status 'Mode' 'Migrate');$state=[string]$status.State;$records=@(Get-Value $status 'Entries' @());$done=0;$removed=[long]0;$kept=[long]0
 for($i=0;$i-lt @($plan.Entries).Count;$i++){
  $entry=$plan.Entries[$i];$record=@($records|Where-Object {$_.Id-eq $entry.Id})|Select-Object -First 1
  $phase='尚未处理'
  if($record){
   $phase=[string]$record.Phase
   if($phase-eq 'complete'){$phase='已迁移';$done++}
   if(Get-Value $record 'Rollback' $false){$phase='已回滚';if($script:currentMode-eq 'Rollback'){$done++}}
   if($record.BackupRemoved){$removed+=[long]$record.Bytes}else{if($record.Verified){$kept+=[long]$record.Bytes}}
  }
  if($status.Current-eq $entry.Source-and $state-in @('copying','verifying','switching','cleaning')){$phase=Get-StateLabel $state}
  if(@(Get-Value $status 'Errors' @()|Where-Object {(Get-Value $_ 'Id' '')-eq $entry.Id}).Count){$phase='遇到错误'}
  $grid.Rows[$i].Cells[2].Value=$phase
 }
 $overall.Value=[Math]::Min($overall.Maximum,$done)
 $summary.Text="目录进度：$done / $(@($plan.Entries).Count)（按目录计数，不代表数据量比例）"
 $stateLabel.Text=Get-StateLabel $state;$stateLabel.ForeColor=[Drawing.SystemColors]::ControlText
 if($state-in @('error','partial_error','directory_error')){$stateLabel.ForeColor=[Drawing.Color]::Firebrick}
 if($state-eq 'complete'){$stateLabel.ForeColor=[Drawing.Color]::DarkGreen}
 $detail.Text=[string]$status.Detail
 if($state-eq 'waiting'){$detail.Text="请保存工作并完全退出下列应用或后台进程。`r`n"+$status.Detail}
 if($state-in @('error','partial_error')){$detail.Text=[string]$status.Detail+"`r`n"+(@(Get-Value $status 'Errors' @()|ForEach-Object {$_.Error})-join "`r`n")}
 $progress.Style='Blocks';$progress.Value=0
 $count=[int](Get-Value $status 'Count' 0);$total=[int](Get-Value $status 'Total' 0)
 if($state-in @('copying','verifying','scanning')){
  if($total-gt 0){$progress.Value=[Math]::Min(100,[int](100.0*$count/$total));$fileLabel.Text="当前目录：$count / $total 个文件"}else{$progress.Style='Marquee';$fileLabel.Text='正在统计文件'}
 }elseif($state-eq 'complete'){$progress.Value=100;$fileLabel.Text='后台任务已完成'}else{$fileLabel.Text='状态变化时自动更新'}
 if($status.File){$fileLabel.Text+='  '+[string]$status.File}
 $backupLabel.Text='已清理原副本：'+(Format-Bytes $removed)+'；仍保留的迁移前副本：'+(Format-Bytes $kept)
 if($script:currentMode-eq 'Rollback'){$backupLabel.Text='回滚保留目标盘数据；恢复时复制的是目标盘最新内容。'}
 $active=$state-notin @('prepared','complete','error','partial_error','cancelled')
 if($active){
  $worker=Get-Process -Id ([int]$status.ProcessId) -ErrorAction SilentlyContinue
  if(-not $worker -or $worker.ProcessName-ne 'powershell' -or $worker.StartTime-gt ([datetimeoffset]::Parse($status.Time).LocalDateTime)){$active=$false;$stateLabel.Text='后台进程已停止，可查看日志后继续';$stateLabel.ForeColor=[Drawing.Color]::Firebrick}
 }
 $retry.Enabled=-not $active;$cancel.Enabled=$active-and $state-notin @('switching','cleaning','restoring_service')
 $updated.Text='后台更新时间：'+([datetimeoffset]::Parse($status.Time).ToLocalTime().ToString('yyyy-MM-dd HH:mm:ss'))+'；界面每秒刷新'
 $grid.ClearSelection()
}
$refresh.Add_Click({try{Update-View}catch{Show-UiError $_.Exception.Message}})
$retry.Add_Click({try{Start-Run $RunDirectory $script:currentMode|Out-Null}catch{Show-UiError $_.Exception.Message}})
$cancel.Add_Click({try{[ChatGPTtMigration.Engine]::AtomicWrite((Join-Path $RunDirectory 'cancel.request'),'cancel');$cancel.Enabled=$false;$note.Text='已请求停止，将在不会破坏原数据的安全点处理。'}catch{Show-UiError $_.Exception.Message}})
$copy.Add_Click({if($script:raw){[Windows.Forms.Clipboard]::SetText($script:raw)}})
$folder.Add_Click({Start-Process -FilePath explorer.exe -ArgumentList ('"'+$RunDirectory+'"')})
$close.Add_Click({$form.Close()})
$timer=New-Object Windows.Forms.Timer;$timer.Interval=1000;$timer.Add_Tick({try{Update-View}catch{$note.Text='刷新暂时失败，将自动重试：'+$_.Exception.Message}})
$form.Add_Shown({Update-View;$timer.Start();$form.Activate()});$form.Add_FormClosed({$timer.Stop();$timer.Dispose()})
if($SelfTest){Update-View;if($grid.Rows.Count-ne @($plan.Entries).Count){throw '进度行数错误。'};if(-not $script:last){throw '状态未加载。'};$form.Dispose();'PROGRESS_UI_TEST_PASSED';return}
[Windows.Forms.Application]::Run($form)
