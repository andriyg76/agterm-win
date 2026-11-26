@echo off
setlocal
cd /d "%~dp0"
set "LOG=%~dp0install-agterm-msix.log"
echo [%date% %time%] install start>>"%LOG%"

if not exist "%~dp0AppxManifest.xml" (
  echo ERROR: run from an MSIX layout folder ^(with AppxManifest.xml^).
  pause
  exit /b 1
)

reg add "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\AppModelUnlock" /v AllowDevelopmentWithoutDevLicense /t REG_DWORD /d 1 /f >>"%LOG%" 2>&1

set "PS=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
"%PS%" -NoProfile -ExecutionPolicy Bypass -File "%~dp0register-msix-layout.ps1" -ManifestPath "%~dp0AppxManifest.xml" >>"%LOG%" 2>&1
if errorlevel 1 (
  echo Register failed. See install-agterm-msix.log
  pause
  exit /b 1
)

call "%~dp0start-agterm-msix.bat"
exit /b %ERRORLEVEL%