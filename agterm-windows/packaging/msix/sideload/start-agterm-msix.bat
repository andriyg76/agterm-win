@echo off
setlocal
cd /d "%~dp0"
set "LOG=%~dp0start-agterm-msix.log"
echo [%date% %time%] start>>"%LOG%"

if not exist "%~dp0agterm-win.exe" (
  echo ERROR: missing agterm-win.exe in layout.
  pause
  exit /b 1
)

start "" /D "%~dp0" "%~dp0agterm-win.exe"
timeout /t 3 /nobreak >nul
tasklist /FI "IMAGENAME eq agterm-win.exe" 2>nul | find /I "agterm-win.exe" >nul
if errorlevel 1 (
  echo WARN: process not seen; try Start menu ^(agterm^).
  exit /b 2
)
echo Started agterm-win.
exit /b 0