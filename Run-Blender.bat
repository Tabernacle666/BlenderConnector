@echo off
setlocal
set "ROOT=%~dp0"
set "TEMP=%ROOT%local\temp"
set "TMP=%TEMP%"
if not exist "%ROOT%vendor\blender\blender.exe" (
 echo Blender absent. Installation portable automatique...
 call "%ROOT%Install.bat"
 if errorlevel 1 exit /b 2
)
start "" "%ROOT%vendor\blender\blender.exe" %*
