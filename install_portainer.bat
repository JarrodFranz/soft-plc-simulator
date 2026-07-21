@echo off
title Installing Portainer CE
echo ============================================
echo  Portainer CE - Docker Standalone Install
echo ============================================
echo.

echo [1/3] Removing any leftover Portainer container...
docker rm -f portainer 2>nul
echo Done.
echo.

echo [2/3] Creating Portainer data volume...
docker volume create portainer_data
echo.

echo [3/3] Starting Portainer CE container...
docker run -d ^
  -p 8000:8000 ^
  -p 9443:9443 ^
  --name portainer ^
  --restart=always ^
  -v /var/run/docker.sock:/var/run/docker.sock ^
  -v portainer_data:/data ^
  portainer/portainer-ce:latest

echo.
if %errorlevel%==0 (
    echo ============================================
    echo  SUCCESS! Portainer is running.
    echo  Open: https://localhost:9443
    echo  (Accept the self-signed cert warning)
    echo ============================================
) else (
    echo ============================================
    echo  ERROR: Something went wrong. See above.
    echo ============================================
)
echo.
pause
