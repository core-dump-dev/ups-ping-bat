@echo off
title UPS Web Monitor
echo Starting UPS Web Monitor...
echo Web UI: http://localhost:9921/
echo Press Ctrl+C to stop.
echo.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0ups_status.ps1" -Mode web
pause