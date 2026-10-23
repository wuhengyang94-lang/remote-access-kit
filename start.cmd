@echo off
rem One-click entry: menu [1] = on-site jump machine, [2] = your local PC.
rem All settings live in config.json next to this file.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0run.ps1" %*
if errorlevel 1 (
    echo.
    echo [FAILED] See the error above.
    pause
)
