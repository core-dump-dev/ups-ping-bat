Set objShell = CreateObject("WScript.Shell")
Set objFSO = CreateObject("Scripting.FileSystemObject")

' Получаем полный путь к текущему VBS-файлу
scriptPath = WScript.ScriptFullName
scriptFolder = objFSO.GetParentFolderName(scriptPath)

' Строим путь к ups_status.ps1 в той же папке
psScriptPath = objFSO.BuildPath(scriptFolder, "ups_status.ps1")

' Запускаем PowerShell скрыто, режим monitor
objShell.Run "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File """ & psScriptPath & """ -Mode monitor", 0, False