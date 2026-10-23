@echo off
rem Typed into the VM's Run box by the host: starts the box test from this USB share.
powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%~dp0boxtest.ps1"
