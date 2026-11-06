@echo off
setlocal
cd /d "%~dp0"
if not exist build mkdir build

odin build src -out:build\aika.exe -subsystem:windows -resource:assets/aika.rc
if errorlevel 1 exit /b 1

odin build src -out:build\aika-cli.exe -resource:assets/aika.rc
if errorlevel 1 exit /b 1

echo Built build\aika.exe and build\aika-cli.exe
