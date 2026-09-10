Set objWMIService = GetObject("winmgmts:\\.\root\cimv2")
Set colProcesses = objWMIService.ExecQuery("SELECT * FROM Win32_Process WHERE Name='powershell.exe' AND CommandLine LIKE '%ups_status.ps1%'")
If colProcesses.Count > 0 Then
    For Each objProcess In colProcesses
        objProcess.Terminate()
    Next
    MsgBox "UPS Web Monitor stopped.", vbInformation, "UPS Monitor"
Else
    MsgBox "No running UPS monitor found.", vbInformation, "UPS Monitor"
End If