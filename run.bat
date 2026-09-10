@echo off
title UPS Web Monitor
echo Запуск UPS Web Monitor...
echo Веб-интерфейс: http://localhost:9921/
echo Ctrl+C для остановки.
echo.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0ups_status.ps1" -Mode web
pause