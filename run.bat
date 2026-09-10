@echo off
title UPS Web Monitor
echo ==================================================
echo  UPS Web Monitor
echo ==================================================
echo.
echo  If you want to access the web UI from OTHER devices
echo  on your network (not just this PC), run these TWO
echo  commands ONCE as Administrator in PowerShell:
echo.
echo  [1] Allow HttpListener to bind to all interfaces:
echo.
echo      netsh http add urlacl url=http://+:9921/ sddl=D:(A;;GX;;;S-1-1-0)
echo.
echo  [2] Open the firewall port:
echo.
echo      New-NetFirewallRule -DisplayName "UPS Web UI" -Direction Inbound -Protocol TCP -LocalPort 9921 -Action Allow
echo.
echo  After that, run this .bat normally (no admin needed).
echo  Other devices can open:  http://YOUR_PC_IP:9921/
echo.
echo ==================================================
echo.
echo Starting UPS Web Monitor...
echo Web UI (local): http://localhost:9921/
echo Press Ctrl+C to stop.
echo.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0ups_status.ps1" -Mode web
pause