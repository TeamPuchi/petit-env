@echo off
setlocal
cd /d "%~dp0\.."

docker info >nul 2>&1
if errorlevel 1 (
  echo Docker Desktop is not running. Start Docker Desktop and try again.
  pause
  exit /b 1
)

if not exist ".env" (
  echo .env not found. Copying .env.example to .env ...
  copy .env.example .env >nul
  echo Edit .env to set CHARACTER_IDS and M5 device IPs, then run this again.
  pause
  exit /b 1
)

docker compose -f docker-compose.release.yml --env-file .env up -d
if errorlevel 1 (
  echo Failed to start petit-env.
  pause
  exit /b 1
)

echo petit-env started. Opening dashboard...
start "" "http://localhost:8765"
echo First time only: run "docker compose -f docker-compose.release.yml exec core claude login" to authenticate.
pause
