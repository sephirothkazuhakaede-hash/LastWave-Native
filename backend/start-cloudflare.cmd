@echo off
setlocal
title CapyFlow Backend + Cloudflare
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\start-cloudflare.ps1"
echo.
echo CapyFlow server stopped.
pause
