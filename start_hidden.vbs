Set objShell = CreateObject("WScript.Shell")
Set objFSO = CreateObject("Scripting.FileSystemObject")

scriptFolder = objFSO.GetParentFolderName(WScript.ScriptFullName)
psScriptPath = objFSO.BuildPath(scriptFolder, "ups_status.ps1")

objShell.Run "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File """ & psScriptPath & """ -Mode web", 0, False