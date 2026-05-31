#!/usr/bin/env bash
set -u
IFS=$'\n\t'

PROJECT_DIR="${SN_PROJECT_DIR:-/opt/standardnotes}"
CONFIG_FILE="$PROJECT_DIR/.install-config"
ENV_FILE="$PROJECT_DIR/.env"

if [[ -t 1 ]]; then
  RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; RESET='\033[0m'
else
  RED=''; GREEN=''; YELLOW=''; BLUE=''; RESET=''
fi

ok() { printf "%b[OK]%b %s\n" "$GREEN" "$RESET" "$*"; }
warn() { printf "%b[WARN]%b %s\n" "$YELLOW" "$RESET" "$*"; }
fail() { printf "%b[FAIL]%b %s\n" "$RED" "$RESET" "$*"; FAILURES=$((FAILURES + 1)); }
info() { printf "%b==>%b %s\n" "$BLUE" "$RESET" "$*"; }

FAILURES=0
NOTES_DOMAIN=""
FILES_DOMAIN=""

if [[ -f "$CONFIG_FILE" ]]; then
  # shellcheck disable=SC1090
  source "$CONFIG_FILE"
fi

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
    fail "$label reached $url but returned HTTP $code"
  elif [[ "$code" =~ ^4 ]]; then
    warn "$label reached $url and returned HTTP $code (reachable, but check endpoint/client config)"
  else
    ok "$label returned HTTP $code: $url"
  fi
}

info "Standard Notes host health check"
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

info "Local service probes"
check_url "API on localhost:3000" "http://127.0.0.1:3000"
check_url "Files server on localhost:3125" "http://127.0.0.1:3125"
check_url "Dashboard on localhost:8090" "http://127.0.0.1:8090/healthz"

if [[ -n "${NOTES_DOMAIN:-}" ]]; then
  info "Public HTTPS probes"
  check_url "Notes HTTPS" "https://${NOTES_DOMAIN}"
else
  warn "NOTES_DOMAIN not found in $CONFIG_FILE"
fi

if [[ -n "${FILES_DOMAIN:-}" ]]; then
  check_url "Files HTTPS" "https://${FILES_DOMAIN}"
else
  warn "FILES_DOMAIN not found in $CONFIG_FILE"
fi

info "Docker status"
if [[ -f "$ENV_FILE" && -f "$PROJECT_DIR/docker-compose.yml" ]]; then
  (cd "$PROJECT_DIR" && docker compose --env-file "$ENV_FILE" ps) || fail "docker compose ps failed"
fi

info "Nginx and Fail2ban"
nginx -t >/tmp/standardnotes-nginx-test.out 2>&1 && ok "nginx configuration test passed" || { fail "nginx configuration test failed"; cat /tmp/standardnotes-nginx-test.out; }
if systemctl is-active --quiet fail2ban; then ok "fail2ban is active"; else warn "fail2ban is not active"; fi

info "Backup status"
if [[ -f "$PROJECT_DIR/backups/LATEST.json" ]]; then
  ok "Latest backup marker: $PROJECT_DIR/backups/LATEST.json"
  if command -v jq >/dev/null 2>&1; then
    jq . "$PROJECT_DIR/backups/LATEST.json" || true
  else
    cat "$PROJECT_DIR/backups/LATEST.json"
  fi
else
  warn "No backup marker yet. Run: sudo $PROJECT_DIR/scripts/backup.sh"
fi

if [[ "$FAILURES" -eq 0 ]]; then
  ok "Health check completed with no hard failures"
else
  fail "Health check completed with $FAILURES hard failure(s)"
fi

exit "$FAILURES"
