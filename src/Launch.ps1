param([switch]$SelfTest)
$ErrorActionPreference='Stop'
try{
 if($PSVersionTable.PSVersion-lt [version]'5.1'){throw '需要 Windows PowerShell 5.1。'}
 & (Join-Path $PSScriptRoot 'Main.ps1') -SelfTest:$SelfTest
}catch{
 if($SelfTest){throw}
 try{Add-Type -AssemblyName System.Windows.Forms;[Windows.Forms.MessageBox]::Show(('程序未能启动，未移动任何文件。'+"`r`n`r`n"+$_.Exception.Message),'ChatGPT迁移助手','OK','Error')|Out-Null}catch{Write-Error '无法打开界面，请从终端运行 src\Main.ps1 查看错误。'}
 exit 1
}
