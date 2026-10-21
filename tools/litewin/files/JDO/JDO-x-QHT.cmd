@echo off
title JDO x QHT
rem Started by the Run key at every sign-in with /auto: waits 5 seconds after the desktop appears, then applies everything.
if /i "%~1"=="/auto" timeout /t 5 /nobreak >nul
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0JDO-x-QHT.ps1"
