@echo off
rem Runs as SYSTEM at the end of Windows setup. Windows skips this file on PCs that install with an OEM key,
rem so autounattend.xml runs the same script again at first logon (firstboot.ps1 only ever runs once).
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%WINDIR%\Setup\Scripts\firstboot.ps1"
