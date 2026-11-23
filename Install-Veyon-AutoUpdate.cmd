@echo off
:: Veyon Updater V1.5.0
setlocal EnableExtensions DisableDelayedExpansion
set "PSModulePath="
chcp 65001 >nul
set "PS_EXE=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
if exist "%SystemRoot%\Sysnative\WindowsPowerShell\v1.0\powershell.exe" set "PS_EXE=%SystemRoot%\Sysnative\WindowsPowerShell\v1.0\powershell.exe"
if not exist "%~dp0Install-Veyon-AutoUpdate.ps1" (
  echo FEHLER: Bitte zuerst die gesamte ZIP-Datei mit "Alle extrahieren" entpacken.
  if not "%VEYON_SETUP_NO_PAUSE%"=="1" pause
  exit /b 2
)
"%PS_EXE%" -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "%~dp0Install-Veyon-AutoUpdate.ps1"
set "RESULT=%ERRORLEVEL%"
if not "%VEYON_SETUP_NO_PAUSE%"=="1" pause
exit /b %RESULT%
