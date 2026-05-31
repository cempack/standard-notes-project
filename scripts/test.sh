#!/usr/bin/env bash
set -u
IFS=$'\n\t'

PROJECT_DIR="${SN_PROJECT_DIR:-/opt/standardnotes}"
CONFIG_FILE="$PROJECT_DIR/.install-config"
ENV_FILE="$PROJECT_DIR/.env"
NOTES_DOMAIN="notes.example.com"
FILES_DOMAIN="files.example.com"

if [[ -f "$CONFIG_FILE" ]]; then
  # shellcheck disable=SC1090
  source "$CONFIG_FILE"
fi

run() {
  printf '\n$ %s\n' "$*"
  "$@"
}

cat <<INFO
Standard Notes verification commands
====================================

Expected public ports:
  - TCP 80: only for HTTP->HTTPS redirect and Let's Encrypt renewal
  - TCP 443: Standard Notes API, files server, and dashboard over HTTPS

Expected private localhost ports:
  - 127.0.0.1:3000 -> Standard Notes API container
  - 127.0.0.1:3125 -> Standard Notes files server container
  - 127.0.0.1:8090 -> dashboard app behind Nginx Basic Auth

INFO

run curl -I "https://${NOTES_DOMAIN}"
run curl -I "https://${FILES_DOMAIN}"
run curl -sS -o /dev/null -w 'API localhost HTTP %{http_code}\n' http://127.0.0.1:3000
run curl -sS -o /dev/null -w 'Files localhost HTTP %{http_code}\n' http://127.0.0.1:3125

if [[ -f "$ENV_FILE" ]]; then
  printf '\n$ cd %s && docker compose --env-file .env ps\n' "$PROJECT_DIR"
  (cd "$PROJECT_DIR" && docker compose --env-file .env ps)
fi

printf '\nRun the full health checker with:\n  sudo %s/scripts/healthcheck.sh\n' "$PROJECT_DIR"
printf '\nStandard Notes client sync test:\n  1. Open the desktop or mobile app.\n  2. Go to Account menu -> Advanced options -> Sync Server -> Custom.\n  3. Enter https://%s\n  4. Register a new account, create a note, sync, then check Docker logs if needed.\n' "$NOTES_DOMAIN"
