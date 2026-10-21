@echo off
title JDO x QHT - tweaks
rem /auto = started by the sign-in list: waits 5 seconds after the desktop appears. By hand: runs at once and stays open.
if /i "%~1"=="/auto" (
  timeout /t 5 /nobreak >nul
  powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0JDO-x-QHT.ps1" -Auto
) else (
  powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0JDO-x-QHT.ps1"
)
