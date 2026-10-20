@echo off
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Run-Patch.ps1" -Target "%~1" -Mode Apply
set "PCL_RESULT=%errorlevel%"
pause
exit /b %PCL_RESULT%
