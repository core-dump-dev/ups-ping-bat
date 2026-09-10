@echo off
title UPS Monitor - Visible
echo Starting UPS monitor (visible mode)...
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0ups_status.ps1" -Mode monitor
pause