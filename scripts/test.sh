#!/usr/bin/env bash
set -u
IFS=$'\n\t'

PROJECT_DIR="${SN_PROJECT_DIR:-/opt/standardnotes}"
CONFIG_FILE="$PROJECT_DIR/.install-config"
ENV_FILE="$PROJECT_DIR/.env"
NOTES_DOMAIN="notes.example.com"
FILES_DOMAIN="files.example.com"

# Source shared UI library
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=ui.sh
source "$SCRIPT_DIR/ui.sh" 2>/dev/null || true

# Fallback if ui.sh didn't load
if [[ -z "${UI_VERSION:-}" ]]; then
  if [[ -t 1 ]]; then
    RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'
    CYAN='\033[0;36m'; BOLD='\033[1m'; DIM='\033[2m'; RESET='\033[0m'
  else
    RED=''; GREEN=''; YELLOW=''; BLUE=''; CYAN=''; BOLD=''; DIM=''; RESET=''
  fi
fi

if [[ -f "$CONFIG_FILE" ]]; then
  # shellcheck disable=SC1090
  source "$CONFIG_FILE"
fi

run() {
  printf '\n  %b$%b %b%s%b\n' "$DIM" "$RESET" "$CYAN" "$*" "$RESET"
  "$@"
}

# Header
printf '\n'
printf '%b┌──────────────────────────────────────────────┐%b\n' "$CYAN" "$RESET"
printf '%b│%b  🧪  Standard Notes Verification              %b│%b\n' "$CYAN" "$BOLD" "$CYAN" "$RESET"
printf '%b└──────────────────────────────────────────────┘%b\n' "$CYAN" "$RESET"
printf '\n'

printf '%b━━━ ▸ Expected Port Layout ◂ ━━━%b\n\n' "$CYAN$BOLD" "$RESET"

printf '  %bPublic:%b\n' "$BOLD" "$RESET"
printf '    %b•%b TCP 80    %b→%b HTTP redirect + Let'\''s Encrypt renewal\n' "$CYAN" "$RESET" "$DIM" "$RESET"
printf '    %b•%b TCP 443   %b→%b HTTPS: API, files, dashboard\n\n' "$CYAN" "$RESET" "$DIM" "$RESET"

printf '  %bPrivate (localhost only):%b\n' "$BOLD" "$RESET"
printf '    %b•%b 127.0.0.1:3000  %b→%b Standard Notes API\n' "$CYAN" "$RESET" "$DIM" "$RESET"
printf '    %b•%b 127.0.0.1:3125  %b→%b Files server\n' "$CYAN" "$RESET" "$DIM" "$RESET"
printf '    %b•%b 127.0.0.1:8090  %b→%b Dashboard (behind Nginx Basic Auth)\n' "$CYAN" "$RESET" "$DIM" "$RESET"

printf '\n%b━━━ ▸ HTTPS Endpoint Tests ◂ ━━━%b\n' "$CYAN$BOLD" "$RESET"
run curl -I "https://${NOTES_DOMAIN}"
run curl -I "https://${FILES_DOMAIN}"

printf '\n%b━━━ ▸ Local Endpoint Tests ◂ ━━━%b\n' "$CYAN$BOLD" "$RESET"
run curl -sS -o /dev/null -w 'API localhost HTTP %{http_code}\n' http://127.0.0.1:3000
run curl -sS -o /dev/null -w 'Files localhost HTTP %{http_code}\n' http://127.0.0.1:3125

if [[ -f "$ENV_FILE" ]]; then
  printf '\n%b━━━ ▸ Docker Compose Status ◂ ━━━%b\n' "$CYAN$BOLD" "$RESET"
  printf '\n  %b$%b %bcd %s && docker compose --env-file .env ps%b\n' "$DIM" "$RESET" "$CYAN" "$PROJECT_DIR" "$RESET"
  (cd "$PROJECT_DIR" && docker compose --env-file .env ps)
fi

printf '\n'
printf '%b━━━ ▸ Next Steps ◂ ━━━%b\n\n' "$CYAN$BOLD" "$RESET"
printf '  Full health check:\n'
printf '    %b$%b %bsudo %s/scripts/healthcheck.sh%b\n\n' "$DIM" "$RESET" "$CYAN" "$PROJECT_DIR" "$RESET"
printf '  Standard Notes client sync test:\n'
printf '    %b①%b Open the desktop or mobile app\n' "$CYAN$BOLD" "$RESET"
printf '    %b②%b Go to Account → Advanced options → Sync Server → Custom\n' "$CYAN$BOLD" "$RESET"
printf '    %b③%b Enter: %bhttps://%s%b\n' "$CYAN$BOLD" "$RESET" "$BOLD" "$NOTES_DOMAIN" "$RESET"
printf '    %b④%b Register a new account, create a note, sync\n' "$CYAN$BOLD" "$RESET"
printf '    %b⑤%b Check Docker logs if needed\n\n' "$CYAN$BOLD" "$RESET"
