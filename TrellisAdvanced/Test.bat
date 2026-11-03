@echo off
setlocal
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0TrellisAdvanced.ps1" -SelfTest
if errorlevel 1 (echo FAILED & exit /b 1)
echo Test des parametres OK. Le GPU n'a pas ete execute.
