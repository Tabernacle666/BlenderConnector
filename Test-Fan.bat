@echo off
setlocal
if not exist "%~dp0input\fan50s.glb" (
 echo Placer fan50s.glb dans "%~dp0input\" avant le test.
 pause
 exit /b 2
)
copy /Y "%~dp0examples\inspect-fan50s.json" "%~dp0jobs\inspect-fan50s.json" >nul
call "%~dp0Run-Once.bat"
