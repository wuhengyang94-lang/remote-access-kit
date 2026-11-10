@echo off
rem Double-click entry: opens the GUI (the script self-elevates).
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0gui.ps1"
if errorlevel 1 pause
