@echo off
setlocal
if not exist "%~dp0vendor\blender\blender.exe" (
 call "%~dp0Install.bat"
 if errorlevel 1 exit /b 2
)
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Watch.ps1" -Once
if errorlevel 1 pause
