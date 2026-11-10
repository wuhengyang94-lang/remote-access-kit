@echo off
rem Double-click (no args) opens the GUI. With args, runs the console engines:
rem   start.cmd -Mode 2 -VerifyOnly
if "%~1"=="" (
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0gui.ps1"
) else (
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0run.ps1" %*
)
if errorlevel 1 (
    echo.
    echo [FAILED] See the error above.
    pause
)
