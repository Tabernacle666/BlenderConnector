@echo off
setlocal
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Install-Blender.ps1"
if errorlevel 1 (
 echo Installation echouee. Voir les messages ci-dessus.
 pause
 exit /b 1
)
echo Installation terminee.
pause
