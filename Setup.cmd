@echo off
start "" powershell.exe -NoProfile -NoLogo -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File "%~dp0Setup.ps1"
