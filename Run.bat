@echo off
REM FTP Manager runner - runs FtpManager.ps1 with current config.json
cd /d "%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -File ".\FtpManager.ps1" %*
echo.
echo Exit code: %ERRORLEVEL%
pause
