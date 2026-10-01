@echo off
REM Build FtpConfigEditor.exe from ConfigEditor.cs (no extra tools needed, uses .NET Framework csc)
cd /d "%~dp0"
C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe /t:winexe /out:FtpConfigEditor.exe ConfigEditor.cs /r:System.Windows.Forms.dll /r:System.Drawing.dll /r:System.Web.Extensions.dll
echo.
echo Exit code: %ERRORLEVEL%
pause
