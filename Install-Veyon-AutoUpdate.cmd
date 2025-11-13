@echo off
:: Veyon Auto-Update Einrichtung (Start bei Systemstart)
:: Copyright Roman Glos 12.11.2025 V1.0
chcp 65001 >nul
setlocal EnableExtensions
title Veyon Auto-Update Einrichtung (Start bei Systemstart)

:: Self-elevate (UAC)
net session >nul 2>&1
if %errorlevel% neq 0 (
  echo.
  echo Administratorrechte werden angefordert ...
  powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
  exit /b
)

set "SRC_DIR=%~dp0"
set "DST_DIR=C:\ProgramData\Veyon\Update"
set "PS_FILE=Veyon-AutoUpdate.ps1"
set "DST_PS=%DST_DIR%\%PS_FILE%"
set "TASK_NAME=Veyon AutoUpdate (winget)"

echo.
echo [1/4] Zielordner vorbereiten: "%DST_DIR%"
if not exist "%DST_DIR%" mkdir "%DST_DIR%"

echo [2/4] PowerShell-Skript kopieren ...
if exist "%SRC_DIR%%PS_FILE%" (
  copy /Y "%SRC_DIR%%PS_FILE%" "%DST_PS%" >nul
) else (
  echo [FEHLER] "%PS_FILE%" nicht im gleichen Ordner wie dieses Installationsprogramm gefunden.
  echo Vorgang abgebrochen.
  pause
  exit /b 2
)

echo [3/4] Geplante Aufgabe anlegen (SYSTEM, bei Systemstart mit 2 Min. Verzögerung) ...
schtasks /Create /TN "%TASK_NAME%" /SC ONSTART /DELAY 0002:00 /RU "SYSTEM" /RL HIGHEST /TR "powershell.exe -NoProfile -ExecutionPolicy Bypass -File \"%DST_PS%\"" /F >nul
if errorlevel 1 (
  echo [FEHLER] Konnte geplante Aufgabe nicht anlegen.
  echo Bitte prüfen Sie Antivirus/Policies und versuchen Sie es erneut.
  pause
  exit /b 3
)

echo [4/4] Testlauf jetzt starten (nur Online-Prüfung, ohne Installation/Backups) ...
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%DST_PS%" -Testlauf
if errorlevel 1 (
  echo Hinweis: Der Testlauf meldete einen Fehler. Details siehe Logdatei unten.
)

echo.
echo FERTIG.
echo Die automatische Aktualisierung für Veyon wurde eingerichtet.
echo - Ausführung: Bei jedem Systemstart (ca. 2 Min. nach Start)
echo - Logdatei  : C:\ProgramData\Veyon\Update\veyon_autoupdate.log
echo.
echo Copyright Roman Glos 12.11.2025 V1.0 für Realschule Roth
echo Dieses Fenster kann jetzt geschlossen werden.
pause
endlocal
