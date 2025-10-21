@echo off
REM Batch file: Copy Windows Assets.bat
REM Runs the script and sets the base destination to the Windows folder
powershell -ExecutionPolicy Bypass -NoLogo -NoProfile -File "%~dp0Windows\Assets.ps1" -BaseDestination "%~dp0Windows"
pause
