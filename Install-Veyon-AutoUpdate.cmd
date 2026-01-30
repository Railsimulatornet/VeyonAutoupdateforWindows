@echo off
:: Veyon Auto-Update Einrichtung (Start bei Systemstart)
:: Copyright Roman Glos 30.01.2026 V1.2
chcp 65001 >nul
setlocal EnableExtensions EnableDelayedExpansion
title Veyon Auto-Update Einrichtung (Start bei Systemstart)

:: ------------------------------------------------------------
:: Schutz: Wenn Script direkt aus ZIP (Windows Explorer) gestartet wurde,
::         automatisch nach %TEMP% entpacken und von dort neu starten.
:: ------------------------------------------------------------
set "SELF=%~f0"
echo(%SELF% | find /I ".zip\" >nul
if not errorlevel 1 (
  powershell -NoProfile -ExecutionPolicy Bypass -Command ^
    "$p='%~f0'; $i=$p.ToLower().IndexOf('.zip\');" ^
    "if($i -ge 0){" ^
    "  $zip=$p.Substring(0,$i+4);" ^
    "  $dest=Join-Path $env:TEMP 'VeyonAutoUpdate_Extract';" ^
    "  Remove-Item $dest -Recurse -Force -ErrorAction SilentlyContinue;" ^
    "  Expand-Archive -LiteralPath $zip -DestinationPath $dest -Force;" ^
    "  $cmd = Get-ChildItem -Path $dest -Recurse -Filter 'Install-Veyon-AutoUpdate.cmd' -ErrorAction SilentlyContinue | Select-Object -First 1;" ^
    "  if($cmd){" ^
    "    Start-Process -FilePath $cmd.FullName -Verb RunAs" ^
    "  } else {" ^
    "    Write-Host 'FEHLER: Install-Veyon-AutoUpdate.cmd wurde nach dem Entpacken nicht gefunden.' -ForegroundColor Red;" ^
    "    Write-Host ('ZIP: ' + $zip);" ^
    "    Write-Host ('Ziel: ' + $dest);" ^
    "    Read-Host 'Enter zum Schließen'" ^
    "  }" ^
    "}"
  exit /b 0
)

:: Fallback: Wenn Begleitdateien fehlen, klare Meldung ausgeben
if not exist "%~dp0Remove-Veyon-AutoUpdate.cmd" (
  echo.
  echo FEHLER: Das Paket wurde vermutlich nicht entpackt.
  echo Bitte Rechtsklick auf die ZIP-Datei -> "Alle extrahieren..." und dann erneut starten.
  echo.
  pause
  exit /b 1
)

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

echo [3/4] Geplante Aufgabe anlegen (SYSTEM, Start/Anmeldung mit 2 Min. Verzögerung) ...

:: Fast Startup erkennen (Hybrid-Boot): HiberbootEnabled=1
set "SC=ONSTART"
set "SC_TEXT=Systemstart (Fast Startup aus)"
set "HIBERBOOT=0x0"

for /f "tokens=3" %%A in ('reg query "HKLM\SYSTEM\CurrentControlSet\Control\Session Manager\Power" /v HiberbootEnabled 2^>nul ^| find /I "HiberbootEnabled"') do (
  set "HIBERBOOT=%%A"
)

if /I "%HIBERBOOT%"=="0x1" (
  set "SC=ONLOGON"
  set "SC_TEXT=Benutzeranmeldung (Fast Startup aktiv)"
)

:: Bei drüberinstallieren: vorhandenen Task entfernen
schtasks /Delete /TN "%TASK_NAME%" /F >nul 2>&1

:: Task neu anlegen
schtasks /Create /TN "%TASK_NAME%" /SC %SC% /DELAY 0002:00 /RU "SYSTEM" /RL HIGHEST ^
  /TR "powershell.exe -NoProfile -ExecutionPolicy Bypass -File ""%DST_PS%""" /F >nul

if errorlevel 1 (
  echo [FEHLER] Konnte geplante Aufgabe nicht anlegen.
  echo Bitte pruefen Sie Antivirus/Policies und versuchen Sie es erneut.
  pause
  exit /b 3
)

echo Trigger: %SC_TEXT%

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
echo Copyright Roman Glos 24.01.2026 V1.1 für Realschule Roth
echo Dieses Fenster kann jetzt geschlossen werden.
pause
endlocal
