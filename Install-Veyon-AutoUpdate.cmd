@echo off
:: Veyon Auto-Update Einrichtung (Start bei Systemstart)
:: Copyright Roman Glos 30.01.2026 V1.4
chcp 65001 >nul
setlocal EnableExtensions DisableDelayedExpansion
title Veyon Auto-Update Einrichtung (Start bei Systemstart)

:: ------------------------------------------------------------
:: Schutz: Wenn Script direkt aus ZIP (Windows Explorer) gestartet wurde,
::         automatisch nach %TEMP% entpacken und von dort neu starten.
:: ------------------------------------------------------------
set "SELF=%~f0"
set "PS_EXE=powershell.exe"
if exist "%SystemRoot%\Sysnative\WindowsPowerShell\v1.0\powershell.exe" set "PS_EXE=%SystemRoot%\Sysnative\WindowsPowerShell\v1.0\powershell.exe"
echo("%SELF%" | find /I ".zip\" >nul
if not errorlevel 1 (
  "%PS_EXE%" -NoProfile -ExecutionPolicy Bypass -Command ^
    "$p=$env:SELF; $i=$p.ToLower().IndexOf('.zip\');" ^
    "if($i -ge 0){" ^
    "  $zip=$p.Substring(0,$i+4);" ^
    "  $dest=Join-Path $env:TEMP 'VeyonAutoUpdate_Extract';" ^
    "  Remove-Item $dest -Recurse -Force -ErrorAction SilentlyContinue;" ^
    "  Expand-Archive -LiteralPath $zip -DestinationPath $dest -Force;" ^
    "  $cmd = Get-ChildItem -Path $dest -Recurse -Filter 'Install-Veyon-AutoUpdate.cmd' -ErrorAction SilentlyContinue | Select-Object -First 1;" ^
    "  if($cmd){" ^
    "    exit (Start-Process -FilePath $cmd.FullName -Verb RunAs -Wait -PassThru -ErrorAction Stop).ExitCode" ^
    "  } else {" ^
    "    Write-Host 'FEHLER: Install-Veyon-AutoUpdate.cmd wurde nach dem Entpacken nicht gefunden.' -ForegroundColor Red;" ^
    "    Write-Host ('ZIP: ' + $zip);" ^
    "    Write-Host ('Ziel: ' + $dest);" ^
    "    Read-Host 'Enter zum Schließen'; exit 1" ^
    "  }" ^
    "}"
  exit /b
)

:: Fallback: Wenn Begleitdateien fehlen, klare Meldung ausgeben
if not exist "%~dp0Remove-Veyon-AutoUpdate.cmd" (
  echo.
  echo FEHLER: Das Paket wurde vermutlich nicht entpackt.
  echo Bitte Rechtsklick auf die ZIP-Datei -> "Alle extrahieren..." und dann erneut starten.
  echo.
  if not "%VEYON_SETUP_NO_PAUSE%"=="1" pause
  exit /b 1
)

:: Self-elevate (UAC)
net session >nul 2>&1
if %errorlevel% neq 0 (
  echo.
  echo Administratorrechte werden angefordert ...
  "%PS_EXE%" -NoProfile -ExecutionPolicy Bypass -Command "exit (Start-Process -FilePath $env:SELF -Verb RunAs -Wait -PassThru -ErrorAction Stop).ExitCode"
  exit /b
)

set "SRC_DIR=%~dp0"
set "DST_DIR=C:\ProgramData\Veyon\Update"
set "PS_FILE=Veyon-AutoUpdate.ps1"
set "DST_PS=%DST_DIR%\%PS_FILE%"
set "TASK_SETUP=%SRC_DIR%Register-Veyon-AutoUpdateTask.ps1"

if not exist "%SRC_DIR%%PS_FILE%" (
  echo [FEHLER] "%PS_FILE%" fehlt. Bitte das Paket erneut entpacken.
  if not "%VEYON_SETUP_NO_PAUSE%"=="1" pause
  exit /b 2
)

if not exist "%TASK_SETUP%" (
  echo [FEHLER] "Register-Veyon-AutoUpdateTask.ps1" fehlt. Bitte das Paket erneut entpacken.
  if not "%VEYON_SETUP_NO_PAUSE%"=="1" pause
  exit /b 2
)

echo.
echo [1/4] Zielordner vorbereiten: "%DST_DIR%"
if not exist "%DST_DIR%" mkdir "%DST_DIR%"

echo [2/4] PowerShell-Skript kopieren ...
copy /Y "%SRC_DIR%%PS_FILE%" "%DST_PS%" >nul
if errorlevel 1 (
  echo [FEHLER] Skript konnte nicht kopiert werden. Vorhandene Aufgabe bleibt erhalten.
  if not "%VEYON_SETUP_NO_PAUSE%"=="1" pause
  exit /b 2
)

echo [3/4] Testlauf jetzt starten (nur lokale Dateiversion, keine Online-Abfrage) ...
"%PS_EXE%" -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "%DST_PS%" -Testlauf
if errorlevel 1 (
  echo [FEHLER] Testlauf fehlgeschlagen. Vorhandene Aufgabe bleibt erhalten.
  if not "%VEYON_SETUP_NO_PAUSE%"=="1" pause
  exit /b 4
)

echo [4/4] Geplante Aufgabe anlegen (SYSTEM, Start/Anmeldung mit 2 Min. Verzögerung) ...
"%PS_EXE%" -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "%TASK_SETUP%" -UpdaterPath "%DST_PS%"
if errorlevel 1 (
  echo [FEHLER] Geplante Aufgabe konnte nicht eingerichtet werden.
  if not "%VEYON_SETUP_NO_PAUSE%"=="1" pause
  exit /b 3
)

echo.
echo FERTIG.
echo Die automatische Aktualisierung für Veyon wurde eingerichtet.
echo - Logdatei  : C:\ProgramData\Veyon\Update\veyon_autoupdate.log
echo.
echo Copyright Roman Glos 24.01.2026 V1.4 für Realschule Roth
echo Dieses Fenster kann jetzt geschlossen werden.
if not "%VEYON_SETUP_NO_PAUSE%"=="1" pause
exit /b 0
