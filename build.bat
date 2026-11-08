@echo off
setlocal
cd /d "%~dp0"
if not exist build mkdir build

where odin >nul 2>nul
if errorlevel 1 (
  echo ERROR: 'odin' was not found on PATH.
  echo If Odin works in your terminal but not here, it is likely added by the
  echo terminal profile only. Add Odin to the system PATH instead, then retry
  echo in a new window.
  pause
  exit /b 1
)

:: Optional: set AIKA_VERSION (e.g. 1.2.3) to stamp the version shown in the status bar.
set "VERSION_FLAG="
if defined AIKA_VERSION set "VERSION_FLAG=-define:AIKA_VERSION=%AIKA_VERSION%"

odin build src -out:build\aika.exe -subsystem:windows -resource:assets/aika.rc %VERSION_FLAG%
if errorlevel 1 (
  echo BUILD FAILED: GUI build. If build\aika.exe is currently running, Exit it
  echo from the tray icon first - Windows locks a running EXE - then retry.
  pause
  exit /b 1
)

odin build src -out:build\aika-cli.exe -resource:assets/aika.rc %VERSION_FLAG%
if errorlevel 1 (
  echo BUILD FAILED: CLI build.
  pause
  exit /b 1
)

echo Built build\aika.exe and build\aika-cli.exe
