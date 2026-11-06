@echo off
setlocal
cd /d "%~dp0"
if not exist build mkdir build

odin build src -out:build\aika.exe -define:RAYLIB_SHARED=true -subsystem:windows
if errorlevel 1 exit /b 1

odin build src -out:build\aika-cli.exe -define:RAYLIB_SHARED=true
if errorlevel 1 exit /b 1

copy /Y vendor\raylib\raylib.dll build\raylib.dll >nul
if errorlevel 1 exit /b 1

echo Built build\aika.exe and build\aika-cli.exe
