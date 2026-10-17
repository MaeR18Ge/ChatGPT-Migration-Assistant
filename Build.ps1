param()
$ErrorActionPreference='Stop'
$root=$PSScriptRoot;$dist=Join-Path $root 'dist';[IO.Directory]::CreateDirectory($dist)|Out-Null
$package=Join-Path $dist 'ChatGPT迁移助手-1.0.zip'
$items=@('Start.vbs','Start.cmd','README.md','src','tests','docs','Build.ps1')|ForEach-Object {Join-Path $root $_}
Compress-Archive -LiteralPath $items -DestinationPath $package -Force
$hash=(Get-FileHash -LiteralPath $package -Algorithm SHA256).Hash
[IO.File]::WriteAllText((Join-Path $dist 'SHA256.txt'),($hash+'  '+[IO.Path]::GetFileName($package)+[Environment]::NewLine),(New-Object Text.UTF8Encoding($false)))
Write-Output $package
Write-Output ('SHA256 '+$hash)
