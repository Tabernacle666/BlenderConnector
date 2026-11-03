@echo off
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Enable-Scripts.ps1"
if errorlevel 1 pause
