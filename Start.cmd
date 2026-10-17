@echo off
set "chatgptt_script=%~dp0src\Launch.ps1"
cd /d "%TEMP%"
start "" "%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -STA -ExecutionPolicy Bypass -WindowStyle Hidden -File "%chatgptt_script%"
