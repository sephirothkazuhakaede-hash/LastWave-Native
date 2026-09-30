@echo off
setlocal
set BIND_HOST=0.0.0.0
set ALLOW_LAN=true
set ALLOW_ANONYMOUS_LAN=true
set AUTH_MODE=local
echo Starting CapyFlow for trusted home-network testing only.
echo Stop it before joining an untrusted network.
call "%~dp0start.cmd"
exit /b %errorlevel%
