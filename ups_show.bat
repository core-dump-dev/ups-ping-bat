@echo off
title UPS Status - Quick View
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0ups_status.ps1" -Mode show
echo.
pause