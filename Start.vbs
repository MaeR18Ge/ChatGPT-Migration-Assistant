Option Explicit
Dim shell, fs, script
Set shell = CreateObject("WScript.Shell")
Set fs = CreateObject("Scripting.FileSystemObject")
script = fs.BuildPath(fs.GetParentFolderName(WScript.ScriptFullName), "src\Launch.ps1")
shell.CurrentDirectory = shell.ExpandEnvironmentStrings("%TEMP%")
shell.Run "powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -WindowStyle Hidden -File """ & script & """", 0, False
