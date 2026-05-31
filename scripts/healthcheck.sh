#!/usr/bin/env bash
set -u
IFS=$'\n\t'

PROJECT_DIR="${SN_PROJECT_DIR:-/opt/standardnotes}"
CONFIG_FILE="$PROJECT_DIR/.install-config"
ENV_FILE="$PROJECT_DIR/.env"

# Source shared UI library
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=ui.sh
source "$SCRIPT_DIR/ui.sh" 2>/dev/null || true

# Fallback if ui.sh didn't load
if [[ -z "${UI_VERSION:-}" ]]; then
  if [[ -t 1 ]]; then
    RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'
    CYAN='\033[0;36m'; MAGENTA='\033[0;35m'; BOLD='\033[1m'; DIM='\033[2m'; RESET='\033[0m'
  else
    RED=''; GREEN=''; YELLOW=''; BLUE=''; CYAN=''; MAGENTA=''; BOLD=''; DIM=''; RESET=''
  fi
fi

ok()   { printf '%b  ✓%b %s\n' "$GREEN" "$RESET" "$*"; }
warn() { printf '%b  ⚠%b %s\n' "$YELLOW" "$RESET" "$*"; }
fail() { printf '%b  ✗%b %s\n' "$RED" "$RESET" "$*"; FAILURES=$((FAILURES + 1)); }
info() { printf '\n%b━━━ ▸ %s ◂ ━━━%b\n' "$CYAN$BOLD" "$*" "$RESET"; }

FAILURES=0
NOTES_DOMAIN=""
FILES_DOMAIN=""

if [[ -f "$CONFIG_FILE" ]]; then
  # shellcheck disable=SC1090
  source "$CONFIG_FILE"
fi

# Print header
printf '\n'
if type show_banner &>/dev/null; then
  show_banner
else
  printf '%b┌──────────────────────────────────────────────┐%b\n' "$CYAN" "$RESET"
  printf '%b│%b  🩺  Standard Notes Health Check              %b│%b\n' "$CYAN" "$BOLD" "$CYAN" "$RESET"
  printf '%b└──────────────────────────────────────────────┘%b\n' "$CYAN" "$RESET"
fi
printf '\n'

check_command() {
  if command -v "$1" >/dev/null 2>&1; then ok "Command available: $1"; else fail "Missing command: $1"; fi
}

check_url() {
  local label="$1" url="$2" insecure="${3:-no}" code curl_args
  curl_args=(-sS -o /dev/null -w '%{http_code}' --max-time 8)
  [[ "$insecure" == "yes" ]] && curl_args=(-k "${curl_args[@]}")
  code="$(curl "${curl_args[@]}" "$url" 2>/dev/null || printf '000')"
  if [[ "$code" == "000" ]]; then
    fail "$label is not reachable: $url"
  elif [[ "$code" =~ ^5 ]]; then
    fail "$label returned HTTP $code: $url"
  elif [[ "$code" =~ ^4 ]]; then
    warn "$label returned HTTP $code: $url (reachable, check endpoint config)"
  else
    ok "$label returned HTTP $code: $url"
  fi
}

info "Prerequisites"
check_command docker
check_command curl
check_command nginx

if [[ -f "$ENV_FILE" ]]; then
  ok "Found $ENV_FILE"
else
  fail "Missing $ENV_FILE"
fi

if [[ -f "$PROJECT_DIR/docker-compose.yml" ]]; then
  ok "Found docker-compose.yml"
else
  fail "Missing docker-compose.yml"
fi

info "Local Service Probes"
check_url "API on localhost:3000" "http://127.0.0.1:3000"
check_url "Files server on localhost:3125" "http://127.0.0.1:3125"
check_url "Dashboard on localhost:8090" "http://127.0.0.1:8090/healthz"

if [[ -n "${NOTES_DOMAIN:-}" ]]; then
  info "Public HTTPS Probes"
  check_url "Notes HTTPS" "https://${NOTES_DOMAIN}"
else
  warn "NOTES_DOMAIN not found in $CONFIG_FILE"
fi

if [[ -n "${FILES_DOMAIN:-}" ]]; then
  check_url "Files HTTPS" "https://${FILES_DOMAIN}"
else
  warn "FILES_DOMAIN not found in $CONFIG_FILE"
fi

info "Docker Status"
if [[ -f "$ENV_FILE" && -f "$PROJECT_DIR/docker-compose.yml" ]]; then
  (cd "$PROJECT_DIR" && docker compose --env-file "$ENV_FILE" ps) || fail "docker compose ps failed"
fi

info "Nginx & Fail2ban"
nginx -t >/tmp/standardnotes-nginx-test.out 2>&1 && ok "nginx configuration test passed" || { fail "nginx configuration test failed"; cat /tmp/standardnotes-nginx-test.out; }
if systemctl is-active --quiet fail2ban; then ok "fail2ban is active"; else warn "fail2ban is not active"; fi

info "Backup Status"
if [[ -f "$PROJECT_DIR/backups/LATEST.json" ]]; then
  ok "Latest backup marker: $PROJECT_DIR/backups/LATEST.json"
  if command -v jq >/dev/null 2>&1; then
    printf '%b' "$DIM"
    jq . "$PROJECT_DIR/backups/LATEST.json" || true
    printf '%b' "$RESET"
  else
    cat "$PROJECT_DIR/backups/LATEST.json"
  fi
else
  warn "No backup marker yet. Run: sudo $PROJECT_DIR/scripts/backup.sh"
fi

# Final result
printf '\n'
if [[ "$FAILURES" -eq 0 ]]; then
  printf '%b┌──────────────────────────────────────────────┐%b\n' "$GREEN" "$RESET"
  printf '%b│%b  ✓  All checks passed — no hard failures     %b│%b\n' "$GREEN" "$BOLD$GREEN" "$GREEN" "$RESET"
  printf '%b└──────────────────────────────────────────────┘%b\n' "$GREEN" "$RESET"
else
  printf '%b┌──────────────────────────────────────────────┐%b\n' "$RED" "$RESET"
  printf '%b│%b  ✗  Completed with %d hard failure(s)          %b│%b\n' "$RED" "$BOLD$RED" "$FAILURES" "$RED" "$RESET"
  printf '%b└──────────────────────────────────────────────┘%b\n' "$RED" "$RESET"
fi
printf '\n'

exit "$FAILURES"
