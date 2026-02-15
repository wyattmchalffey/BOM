@echo off
setlocal

set "SCRIPT_DIR=%~dp0"

powershell -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT_DIR%run_websocket_host.ps1" %*
exit /b %ERRORLEVEL%
