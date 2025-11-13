@echo off
:: Veyon Auto-Update entfernen
:: Copyright Roman Glos 21.11.2025 V1.0
chcp 65001 >nul
setlocal EnableExtensions
title Veyon Auto-Update entfernen

net session >nul 2>&1
if %errorlevel% neq 0 (
  echo.
  echo Administratorrechte werden angefordert ...
  powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
  exit /b
)

set "DST_DIR=C:\ProgramData\Veyon\Update"
set "TASK_NAME=Veyon AutoUpdate (winget)"

echo [1/3] Geplante Aufgabe löschen ...
schtasks /Delete /TN "%TASK_NAME%" /F >nul 2>&1

echo [2/3] Dateien entfernen ...
if exist "%DST_DIR%" (
  del /F /Q "%DST_DIR%\Veyon-AutoUpdate.ps1" >nul 2>&1
  del /F /Q "%DST_DIR%\veyon_autoupdate.log" >nul 2>&1
  del /F /Q "%DST_DIR%\winget_last.log" >nul 2>&1
  rmdir /S /Q "%DST_DIR%" >nul 2>&1
)

echo [3/3] Fertig. Die Auto-Update-Funktion wurde entfernt.
echo Copyright Roman Glos 12.11.2025 V1.0 für Realschule Roth
pause
endlocal
