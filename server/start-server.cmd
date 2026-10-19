@echo off
rem Starts the JDO license server. Keeps restarting it if it ever stops.
cd /d "%~dp0"
if not exist node_modules (
  echo Installing packages...
  call npm install --omit=dev --no-audit --no-fund
)
:loop
echo [%date% %time%] starting server >> server.log
node src\server.js >> server.log 2>&1
echo [%date% %time%] server stopped, restarting in 5 seconds >> server.log
timeout /t 5 /nobreak >nul
goto loop
