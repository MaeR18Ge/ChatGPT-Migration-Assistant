param([switch]$SelfTest)
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot 'Migration.Core.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'UI.psm1') -Force
Set-Location -LiteralPath ([IO.Path]::GetTempPath())
$form=New-UiForm 'ChatGPT迁移助手 1.0' 1120 740
$title=Add-UiLabel $form 'ChatGPT迁移助手' 25 18 1050 39;$title.Font=New-Object Drawing.Font('Microsoft YaHei UI',22,[Drawing.FontStyle]::Bold)
$subtitle=Add-UiLabel $form '迁移 ChatGPT / Codex 与 ChatCut 本地数据；保留原路径，复制后逐文件校验。' 27 65 1050 25
$null=Add-UiLabel $form '目标位置' 27 106 80 27
$target=Add-UiText $form 108 104 640 29;$target.Anchor='Top,Left,Right'
$browse=Add-UiButton $form '选择目录' 759 101 115;$browse.Anchor='Top,Right'
$scan=Add-UiButton $form '扫描 / 预检' 885 101 207;$scan.Anchor='Top,Right'
$drives=@([IO.DriveInfo]::GetDrives()|Where-Object {$_.IsReady-and $_.DriveType-eq 'Fixed'-and $_.DriveFormat-eq 'NTFS'-and $_.RootDirectory.FullName-ine [IO.Path]::GetPathRoot($env:WINDIR)})
if(@($drives|Where-Object {$_.Name-eq 'E:\'}).Count){$target.Text='E:\'}elseif($drives.Count){$target.Text=$drives[0].RootDirectory.FullName}
$productBoxes=@{};$x=27
foreach($product in @('ChatGPT','Codex','ChatCut')){$box=New-Object Windows.Forms.CheckBox;$box.Text=$product;$box.Checked=$true;$box.Location=New-Object Drawing.Point($x,153);$box.Size=New-Object Drawing.Size(145,28);$form.Controls.Add($box);$productBoxes[$product]=$box;$x+=155}
$keep=New-Object Windows.Forms.CheckBox;$keep.Text='保留原目录副本，确认正常后再清理';$keep.Checked=$true;$keep.Location=New-Object Drawing.Point(27,193);$keep.Size=New-Object Drawing.Size(400,25);$form.Controls.Add($keep)
$helpers=New-Object Windows.Forms.CheckBox;$helpers.Text='迁移时关闭已识别的无窗口连接服务';$helpers.Checked=$true;$helpers.Location=New-Object Drawing.Point(440,193);$helpers.Size=New-Object Drawing.Size(440,25);$form.Controls.Add($helpers)
$services=New-Object Windows.Forms.CheckBox;$services.Text='需要时临时释放 Codex 服务锁，并在结束后恢复服务';$services.Checked=$true;$services.Location=New-Object Drawing.Point(27,224);$services.Size=New-Object Drawing.Size(700,25);$form.Controls.Add($services)
$grid=New-Object Windows.Forms.DataGridView;$grid.Location=New-Object Drawing.Point(27,265);$grid.Size=New-Object Drawing.Size(1065,280);$grid.Anchor='Top,Bottom,Left,Right';$grid.AllowUserToAddRows=$false;$grid.AllowUserToDeleteRows=$false;$grid.AllowUserToResizeRows=$false;$grid.RowHeadersVisible=$false;$grid.SelectionMode='FullRowSelect';$grid.AutoSizeColumnsMode='Fill';$grid.BackgroundColor=[Drawing.SystemColors]::Window;$grid.RowTemplate.Height=28
$selection=New-Object Windows.Forms.DataGridViewCheckBoxColumn;$selection.Name='select';$selection.HeaderText='选';$selection.FillWeight=4;$null=$grid.Columns.Add($selection)
foreach($column in @(@('product','应用',7),@('name','内容',18),@('source','原目录',24),@('destination','目标 / 当前实际目录',24),@('files','文件数',7),@('size','大小',8),@('state','状态',12))){$null=$grid.Columns.Add($column[0],$column[1]);$grid.Columns[$column[0]].FillWeight=[int]$column[2];$grid.Columns[$column[0]].ReadOnly=$true}
foreach($column in $grid.Columns){$column.SortMode='NotSortable'};Set-UiGridHeaders $grid;$form.Controls.Add($grid)
$statusLabel=Add-UiLabel $form '点击扫描检查目录。已迁移的目录只验证，不会重复移动。' 27 561 1065 28;$statusLabel.Anchor='Bottom,Left,Right'
$pathLabel=Add-UiLabel $form '' 27 595 1065 42;$pathLabel.Anchor='Bottom,Left,Right'
$start=Add-UiButton $form '开始迁移' 27 650 150;$start.Anchor='Bottom,Left'
$verify=Add-UiButton $form '校验现有链接' 189 650 150;$verify.Anchor='Bottom,Left'
$history=Add-UiButton $form '历史 / 回滚 / 清理' 351 650 205;$history.Anchor='Bottom,Left'
$help=Add-UiButton $form '使用说明' 568 650 130;$help.Anchor='Bottom,Left'
$note=Add-UiLabel $form '不迁移 WindowsApps 主程序；不会自动结束有界面的应用。共享技能默认不勾选。' 27 701 1065 24;$note.Anchor='Bottom,Left,Right'
$script:Rows=@();$script:Scanning=$false
function Selected-Entries {$null=$grid.EndEdit();@($grid.Rows|Where-Object {$_.Cells[0].Value-eq $true}|ForEach-Object {$script:Rows[$_.Index]})}
function Update-Selection {
 if($script:Scanning){return};$selected=@(Selected-Entries);$bytes=($selected|Measure-Object Bytes -Sum).Sum
 $statusLabel.Text='已选 '+$selected.Count+' 个目录，约 '+(Format-Bytes ([long]$bytes))+'。'+$(if($keep.Checked){'迁移后保留原副本，清理后才释放相应空间。'}else{'校验通过后清理原副本。'})
}
function Scan-Directories {
 if($script:Scanning){return};$script:Scanning=$true;$scan.Enabled=$false;$start.Enabled=$false;$grid.Enabled=$false
 try{
  $statusLabel.Text='正在识别和扫描目录，暂不修改文件。';[Windows.Forms.Application]::DoEvents()
  $products=@($productBoxes.Keys|Where-Object {$productBoxes[$_].Checked});$script:Rows=@(Get-Catalog|Where-Object {$products-contains $_.Product});$grid.Rows.Clear()
  foreach($entry in $script:Rows){
   $statusLabel.Text='正在扫描：'+$entry.Name;[Windows.Forms.Application]::DoEvents()
   $callback=[Action[string,int,int,string]]{param($phase,$count,$total,$file) $statusLabel.Text='正在扫描：'+$entry.Name+'，已发现 '+$count+' 个文件';[Windows.Forms.Application]::DoEvents()}
   if(-not $entry.Error){try{$null=Get-EntryStats $entry $callback}catch{$entry.Error=$_.Exception.Message}}
   $destination=if($entry.Linked){$entry.Current}elseif($target.Text){Get-Destination $entry $target.Text}else{'请选择目标位置'}
   $state=if($entry.Error){'需要处理'}elseif($entry.Linked){'已链接，仅验证'}else{'待迁移'}
   $index=$grid.Rows.Add([object[]]@(($entry.Default-and -not $entry.Linked-and -not $entry.Error),$entry.Product,$entry.Name,$entry.Source,$destination,$entry.Files,(Format-Bytes $entry.Bytes),$state))
   $grid.Rows[$index].Cells[0].ReadOnly=$entry.Linked-or [bool]$entry.Error
   $grid.Rows[$index].Cells['source'].ToolTipText=$entry.Source;$grid.Rows[$index].Cells['destination'].ToolTipText=$destination
   if($entry.Error){$grid.Rows[$index].Cells['state'].ToolTipText=$entry.Error}
  }
  $grid.ClearSelection()
 }catch{if($SelfTest){throw};Show-UiError $_.Exception.Message}finally{$script:Scanning=$false;$scan.Enabled=$true;$start.Enabled=$true;$grid.Enabled=$true;Update-Selection}
}
function Show-History {
 $records=@(Get-History);if(-not $records.Count){Show-UiInfo '暂无本工具创建的任务。以前的迁移可在主界面验证链接，但不属于本工具的回滚或清理范围。';return}
 $h=New-UiForm '历史任务、回滚与清理' 1000 650
 $list=New-Object Windows.Forms.ListBox;$list.Location=New-Object Drawing.Point(25,25);$list.Size=New-Object Drawing.Size(950,190);$list.Anchor='Top,Left,Right';$list.DisplayMember='Label'
 foreach($record in $records){$label=([datetimeoffset]::Parse($record.Plan.Created).ToLocalTime().ToString('yyyy-MM-dd HH:mm'))+' | '+(Get-StateLabel $record.Status.State)+' | '+@($record.Plan.Entries).Count+' 个目录';$null=$list.Items.Add([pscustomobject]@{Label=$label;Record=$record})};$h.Controls.Add($list)
 $text=Add-UiText $h 25 235 950 250 -Multi -ReadOnly;$text.Anchor='Top,Bottom,Left,Right'
 $buttons=@{};$x=25
 foreach($spec in @(@('view','打开进度',120),@('retry','继续迁移',120),@('rollback','回滚最新数据',150),@('cleanup','清理原副本',140),@('export','导出诊断（含路径）',220))){$buttons[$spec[0]]=Add-UiButton $h $spec[1] $x 530 ([int]$spec[2]);$buttons[$spec[0]].Anchor='Bottom,Left';$x+=[int]$spec[2]+10}
 $explanation=Add-UiLabel $h '回滚会复制目标盘的最新数据，且保留目标盘内容。清理只处理本工具记录并验证过的副本。' 25 588 950 45;$explanation.Anchor='Bottom,Left,Right'
 $list.Add_SelectedIndexChanged({if($list.SelectedItem){$r=$list.SelectedItem.Record;$text.Text='任务：'+$r.Plan.Id+"`r`n"+$r.Status.Detail+"`r`n`r`n"+(@($r.Plan.Entries|ForEach-Object {$_.Name+"`r`n"+$_.Source+"`r`n→ "+$_.Destination})-join "`r`n`r`n")}})
 $buttons.view.Add_Click({if($list.SelectedItem){try{$r=$list.SelectedItem.Record;$engine=Join-Path $r.Directory 'engine';Register-IndependentTask (Join-Path $engine 'Progress.ps1') ('-RunDirectory "'+$r.Directory+'"') $r.Directory ('ChatGPTt-View-'+$r.Plan.Id)|Out-Null}catch{Show-UiError $_.Exception.Message}}})
 $buttons.retry.Add_Click({if($list.SelectedItem){try{Start-Run $list.SelectedItem.Record.Directory 'Migrate'|Out-Null}catch{Show-UiError $_.Exception.Message}}})
 $buttons.rollback.Add_Click({if($list.SelectedItem-and (Confirm-Ui '将等待相关应用退出，把目标盘最新数据复制回原目录。目标盘数据保留。需要原盘有足够空间。是否继续？')){try{Start-Run $list.SelectedItem.Record.Directory 'Rollback'|Out-Null}catch{Show-UiError $_.Exception.Message}}})
 $buttons.cleanup.Add_Click({if($list.SelectedItem){$r=$list.SelectedItem.Record;if(Confirm-Ui ('请先确认软件和项目均正常。将永久清理本任务的迁移前原副本；不会删除原路径链接或目标盘数据。'+"`r`n任务："+$r.Plan.Id)){try{Start-Run $r.Directory 'Cleanup'|Out-Null}catch{Show-UiError $_.Exception.Message}}}})
 $buttons.export.Add_Click({if($list.SelectedItem){$save=New-Object Windows.Forms.SaveFileDialog;$save.Filter='诊断压缩包 (*.zip)|*.zip';$save.FileName='ChatGPT迁移助手-诊断-'+$list.SelectedItem.Record.Plan.Id.Substring(0,8)+'.zip';if($save.ShowDialog()-eq 'OK'){try{$r=$list.SelectedItem.Record;$files=@('plan.json','journal.json','status.json','events.log')|ForEach-Object {Join-Path $r.Directory $_}|Where-Object {Test-Path -LiteralPath $_};Compress-Archive -LiteralPath $files -DestinationPath $save.FileName -Force;Show-UiInfo '已导出诊断记录。包含目录路径，不包含迁移的数据文件内容。'}catch{Show-UiError $_.Exception.Message}};$save.Dispose()}})
 $list.SelectedIndex=0;$null=$h.ShowDialog($form);$h.Dispose()
}
$browse.Add_Click({$dialog=New-Object Windows.Forms.FolderBrowserDialog;$dialog.Description='选择目标磁盘或父目录，工具会建立 ChatGPT、Codex、ChatCut 子目录。';if($target.Text-and (Test-Path -LiteralPath $target.Text)){$dialog.SelectedPath=$target.Text};if($dialog.ShowDialog()-eq 'OK'){$target.Text=$dialog.SelectedPath};$dialog.Dispose()})
$scan.Add_Click({Scan-Directories})
$grid.Add_CurrentCellDirtyStateChanged({if($grid.IsCurrentCellDirty){$grid.CommitEdit([Windows.Forms.DataGridViewDataErrorContexts]::Commit)|Out-Null}})
$grid.Add_CellValueChanged({Update-Selection})
$grid.Add_SelectionChanged({if($grid.SelectedRows.Count-and $grid.SelectedRows[0].Index-lt $script:Rows.Count){$entry=$script:Rows[$grid.SelectedRows[0].Index];$pathLabel.Text='原路径：'+$entry.Source+"`r`n实际位置："+$entry.Current}})
$keep.Add_CheckedChanged({Update-Selection})
$start.Add_Click({
 try{
  $entries=@(Selected-Entries);$plan=New-Plan $entries $target.Text $keep.Checked $helpers.Checked $services.Checked
  $review='选定 '+$entries.Count+' 个目录，共 '+(Format-Bytes $plan.Bytes)+'。目标剩余空间：'+(Format-Bytes (Get-FreeBytes $plan.TargetRoot))+"。`r`n`r`n"+(@($plan.Entries|ForEach-Object {$_.Name+' → '+$_.Destination})-join "`r`n")+"`r`n`r`n"+$(if($plan.KeepBackup){'迁移前副本保留，确认软件正常后可通过历史任务清理。'}else{'文件校验成功后将清理原副本。'})+"`r`n任务会等待相关应用退出；开始后可关闭主窗口。"
  if(Confirm-Ui $review){$run=New-Run $plan;Start-Run $run|Out-Null;$statusLabel.Text='独立任务和进度窗口已启动，请保存工作并退出相关应用。'}
 }catch{Show-UiError $_.Exception.Message}
})
$verify.Add_Click({try{$linked=@($script:Rows|Where-Object {$_.Linked});if(-not $linked.Count){Show-UiInfo '扫描结果中没有现有目录链接。';return};$failed=@();foreach($entry in $linked){if(-not(Test-Link $entry.Source $entry.Current)){$failed+=$entry.Source}};if($failed.Count){Show-UiError ($failed-join "`r`n")}else{Show-UiInfo ('已验证 '+$linked.Count+' 个链接：原路径和实际目录均可访问。此检查不等同于重新校验全部文件内容。')}}catch{Show-UiError $_.Exception.Message}})
$history.Add_Click({Show-History})
$help.Add_Click({Show-UiInfo "使用流程：`r`n1. 选择目标盘，扫描并核对目录。`r`n2. 选择要迁移的数据，开始任务。`r`n3. 保存工作并退出相关应用，观察独立进度窗口。`r`n4. 完成后检查软件，再清理原副本。`r`n`r`n已有链接不会重复搬运。主程序安装包不在迁移范围。任务记录在当前用户本地数据目录的 ChatGPTtMigration 文件夹。"})
$form.Add_Shown({Scan-Directories;$form.Activate()})
if($SelfTest){Scan-Directories;if(-not $grid.Columns.Contains('select')){throw '主界面列缺失。'};foreach($entry in $script:Rows){if($entry.Linked-and $grid.Rows[[Array]::IndexOf($script:Rows,$entry)].Cells[0].Value){throw '已有链接被自动选中。'}};$form.Dispose();'MAIN_UI_TEST_PASSED';return}
[Windows.Forms.Application]::Run($form)
