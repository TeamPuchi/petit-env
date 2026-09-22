#!/bin/sh
set -eu

cd "$(dirname "$0")/.."

if ! docker info >/dev/null 2>&1; then
  echo "Docker Desktop is not running. Start Docker Desktop and try again."
  read -r _
  exit 1
fi

if [ ! -f .env ]; then
  echo ".env not found. Copying .env.example to .env ..."
  cp .env.example .env
  echo "Edit .env to set CHARACTER_IDS and M5 device IPs, then run this again."
  read -r _
  exit 1
fi

if ! docker compose -f docker-compose.release.yml --env-file .env up -d; then
  echo "Failed to start petit-env."
  read -r _
  exit 1
fi

echo "petit-env started. Opening dashboard..."
open "http://localhost:8765" >/dev/null 2>&1 || true
echo "First time only: run 'docker compose -f docker-compose.release.yml exec core claude login' to authenticate."
read -r _
