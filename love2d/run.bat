@echo off
setlocal
REM Run Siegecraft with LÖVE. Use this if "love" is not in your PATH.
set "LOVE="
if exist "C:\Program Files\LOVE\love.exe" set "LOVE=C:\Program Files\LOVE\love.exe"
if exist "C:\Program Files (x86)\LOVE\love.exe" set "LOVE=C:\Program Files (x86)\LOVE\love.exe"
if "%LOVE%"=="" (
  echo LÖVE not found. Install from https://love2d.org/ and run this from the love2d folder.
  echo Or add LÖVE to your PATH and use: love .
  pause
  exit /b 1
)

REM Normalize game directory path to avoid stray quote/trailing-slash issues.
for %%I in ("%~dp0.") do set "GAME_DIR=%%~fI"
"%LOVE%" "%GAME_DIR%"
