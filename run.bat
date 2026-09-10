@echo off
title UPS Web Monitor
echo ==================================================
echo  UPS Web Monitor
echo ==================================================
echo.
echo  NOTE: If you want to access the web UI from other
echo  devices on your network, run this ONCE as admin
echo  in PowerShell:
echo.
echo    netsh http add urlacl url=http://+:9921/ sddl=D:(A;;GX;;;S-1-1-0)
echo.
echo  And open the firewall port:
echo.
echo    New-NetFirewallRule -DisplayName "UPS Web UI" -Direction Inbound -Protocol TCP -LocalPort 9921 -Action Allow
echo.
echo ==================================================
echo.
echo Starting UPS Web Monitor...
echo Web UI: http://localhost:9921/
echo Press Ctrl+C to stop.
echo.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0ups_status.ps1" -Mode web
pause