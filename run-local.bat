@echo off
setlocal
title VirtualHub - Local Server
cd /d "%~dp0"

echo.
echo  ===============================================
echo   VirtualHub - Local Test Server
echo  ===============================================
echo.

REM --- Check Node.js is installed ---
where node >nul 2>nul
if errorlevel 1 (
    echo  [ERROR] Node.js is not installed or not on PATH.
    echo          Download it from https://nodejs.org and re-run.
    echo.
    pause
    exit /b 1
)

REM --- Pick port: arg1 ^> env PORT ^> 5173 ---
set "LOCAL_PORT=%~1"
if "%LOCAL_PORT%"=="" set "LOCAL_PORT=%PORT%"
if "%LOCAL_PORT%"=="" set "LOCAL_PORT=5173"

set "LOCAL_HOST=127.0.0.1"

REM --- Kill any previous VirtualHub server bound to the target port so we
REM     don't get EADDRINUSE when re-running without closing the last window.
echo  Releasing port %LOCAL_PORT% (if held by a previous run)...
for /f "tokens=5" %%P in ('netstat -aon ^| findstr ":%LOCAL_PORT% " ^| findstr "LISTENING"') do (
    echo    killing PID %%P
    taskkill /F /PID %%P >nul 2>&1
)
timeout /t 1 /nobreak >nul

echo.
echo  Server:    http://%LOCAL_HOST%:%LOCAL_PORT%/
echo  Dashboard: http://%LOCAL_HOST%:%LOCAL_PORT%/dashboard
echo  Admin:     http://%LOCAL_HOST%:%LOCAL_PORT%/admin
echo  Login:     http://%LOCAL_HOST%:%LOCAL_PORT%/login
echo.
echo  Tips:
echo    - Sign up / login needs a real email (auth goes to Supabase).
echo    - Pages that fetch data need internet.
echo    - Use a custom port:  run-local.bat 8080
echo    - If the port is taken, the server auto-picks the next free one.
echo    - Press Ctrl+C to stop the server.
echo.

REM --- Open the browser in 2s so the server has time to bind the port ---
start "" /b cmd /c "timeout /t 2 /nobreak >nul && start "" "http://%LOCAL_HOST%:%LOCAL_PORT%/""

REM --- Launch the server (blocks until Ctrl+C) ---
node "%~dp0local-server.js" --port "%LOCAL_PORT%"
set "RC=%errorlevel%"

if not "%RC%"=="0" (
    echo.
    echo  [ERROR] Server stopped with exit code %RC%.
    echo          Usually this means another node.exe is still holding the port.
    echo          Open Task Manager, end any "node.exe" process, then re-run.
    echo.
)

pause