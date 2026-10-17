Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[Windows.Forms.Application]::EnableVisualStyles()
function Format-Bytes([long]$Bytes){if($Bytes-ge 1GB){'{0:N2} GiB'-f ($Bytes/1GB)}elseif($Bytes-ge 1MB){'{0:N1} MiB'-f ($Bytes/1MB)}else{'{0:N0} KiB'-f ($Bytes/1KB)}}
function New-UiForm([string]$Title,[int]$Width=1060,[int]$Height=710){
 $form=New-Object Windows.Forms.Form;$form.Text=$Title;$form.StartPosition='CenterScreen';$form.AutoScaleMode='Dpi'
 $form.Font=New-Object Drawing.Font('Microsoft YaHei UI',10);$form.BackColor=[Drawing.SystemColors]::Window
 $form.ClientSize=New-Object Drawing.Size($Width,$Height);$form.MinimumSize=New-Object Drawing.Size(900,640)
 $work=[Windows.Forms.Screen]::PrimaryScreen.WorkingArea
 if($form.Height-gt $work.Height-30){$form.Height=$work.Height-30};if($form.Width-gt $work.Width-30){$form.Width=$work.Width-30}
 $form
}
function Add-UiLabel($Form,[string]$Text,[int]$X,[int]$Y,[int]$Width,[int]$Height=25){$c=New-Object Windows.Forms.Label;$c.Text=$Text;$c.Location=New-Object Drawing.Point($X,$Y);$c.Size=New-Object Drawing.Size($Width,$Height);$Form.Controls.Add($c);$c}
function Add-UiButton($Form,[string]$Text,[int]$X,[int]$Y,[int]$Width=130){$c=New-Object Windows.Forms.Button;$c.Text=$Text;$c.Location=New-Object Drawing.Point($X,$Y);$c.Size=New-Object Drawing.Size($Width,34);$Form.Controls.Add($c);$c}
function Add-UiText($Form,[int]$X,[int]$Y,[int]$Width,[int]$Height=27,[switch]$Multi,[switch]$ReadOnly){$c=New-Object Windows.Forms.TextBox;$c.Location=New-Object Drawing.Point($X,$Y);$c.Size=New-Object Drawing.Size($Width,$Height);$c.Multiline=$Multi;$c.ReadOnly=$ReadOnly;if($Multi){$c.ScrollBars='Vertical'};$Form.Controls.Add($c);$c}
function Set-UiGridHeaders($Grid){
 # Let WinForms measure the inherited font and available column width after DPI scaling.
 $Grid.ColumnHeadersDefaultCellStyle.Alignment='MiddleLeft'
 $Grid.ColumnHeadersDefaultCellStyle.WrapMode='True'
 $Grid.ColumnHeadersDefaultCellStyle.Padding=New-Object Windows.Forms.Padding(3,6,3,6)
 $Grid.ColumnHeadersHeightSizeMode='AutoSize'
}
function Show-UiError([string]$Text){[Windows.Forms.MessageBox]::Show($Text,'ChatGPT迁移助手','OK','Error')|Out-Null}
function Show-UiInfo([string]$Text){[Windows.Forms.MessageBox]::Show($Text,'ChatGPT迁移助手','OK','Information')|Out-Null}
function Confirm-Ui([string]$Text){[Windows.Forms.MessageBox]::Show($Text,'请核对操作内容','YesNo','Question')-eq 'Yes'}
function Get-StateLabel([string]$State){
 $labels=@{prepared='计划已保存';waiting='等待相关应用退出';helper='正在关闭已识别的无窗口连接服务';preparing='正在准备';scanning='正在扫描';copying='正在复制文件';verifying='正在校验文件内容';switching='正在切换原路径';entry_complete='一个目录已完成';stopping_service='正在释放后台文件锁';restoring_service='正在恢复后台服务';cleaning='正在清理原副本';complete='操作完成';partial_error='部分目录未完成';directory_error='一个目录遇到错误';error='操作已停止';cancelled='已安全停止'}
 if($labels.ContainsKey($State)){$labels[$State]}else{$State}
}
Export-ModuleMember -Function *
