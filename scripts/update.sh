#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

PROJECT_DIR="${SN_PROJECT_DIR:-/opt/standardnotes}"
ENV_FILE="$PROJECT_DIR/.env"

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

log()  { printf '%b   [%s]%b %s\n' "$DIM" "$(date -u +%H:%M:%S)" "$RESET" "$*"; }
step() { printf '\n%b━━━ ▸ %s ◂ ━━━%b\n' "$CYAN$BOLD" "$*" "$RESET"; }
ok()   { printf '%b  ✓%b %s\n' "$GREEN" "$RESET" "$*"; }
warn() { printf '%b  ⚠%b %s\n' "$YELLOW" "$RESET" "$*"; }
die()  { printf '%b  ✗%b %s\n' "$RED" "$RESET" "$*" >&2; exit 1; }

[[ -f "$ENV_FILE" ]] || die "Missing $ENV_FILE. Run install.sh first."
[[ -f "$PROJECT_DIR/docker-compose.yml" ]] || die "Missing docker-compose.yml in $PROJECT_DIR"

# Header
printf '\n'
printf '%b┌──────────────────────────────────────────────┐%b\n' "$CYAN" "$RESET"
printf '%b│%b  🚀  Standard Notes Update                   %b│%b\n' "$CYAN" "$BOLD" "$CYAN" "$RESET"
printf '%b└──────────────────────────────────────────────┘%b\n' "$CYAN" "$RESET"
printf '\n'

printf '  This will perform the following steps:\n\n'
printf '  %b①%b  Run a pre-update backup\n' "$CYAN$BOLD" "$RESET"
printf '  %b②%b  Pull latest Docker images\n' "$CYAN$BOLD" "$RESET"
printf '  %b③%b  Recreate containers with %bdocker compose up -d%b\n' "$CYAN$BOLD" "$RESET" "$DIM" "$RESET"
printf '  %b④%b  Run health check\n\n' "$CYAN$BOLD" "$RESET"

printf '  Continue? [y/N]: '
read -r ANSWER
case "$ANSWER" in
  y|Y|yes|YES) ;;
  *) die "Update cancelled." ;;
esac

step "Step 1/4 — Pre-Update Backup"
log "Running pre-update backup"
SN_PROJECT_DIR="$PROJECT_DIR" "$PROJECT_DIR/scripts/backup.sh"
ok "Backup complete"

step "Step 2/4 — Pulling Docker Images"
log "Pulling Docker images"
cd "$PROJECT_DIR"

pull_success=false
max_attempts=3
attempt=1

while (( attempt <= max_attempts )); do
  log "Pull attempt $attempt/$max_attempts"
  if docker compose --env-file "$ENV_FILE" pull 2>&1; then
    pull_success=true
    break
  fi

  if (( attempt < max_attempts )); then
    wait_secs=$(( 30 * attempt ))
    printf '\n'
    warn "Docker pull failed (likely rate limit). Retrying in ${wait_secs}s..."
    printf '\n'
    printf '  %bTip:%b Run %bdocker login%b to authenticate and increase your rate limit.\n' "$BOLD" "$RESET" "$CYAN" "$RESET"
    printf '  Get a free account at %bhttps://hub.docker.com%b\n\n' "$CYAN" "$RESET"

    if [[ -t 0 ]]; then
      printf '  Run docker login now? [y/N]: '
      read -r login_answer
      case "$login_answer" in
        y|Y|yes|YES) docker login || warn "Docker login failed. Continuing." ;;
      esac
    fi

    sleep "$wait_secs"
  fi
  attempt=$((attempt + 1))
done

if [[ "$pull_success" != "true" ]]; then
  printf '\n'
  printf '  %b✗  All Docker pull attempts failed.%b\n' "$BOLD$RED" "$RESET"
  printf '  Create a free Docker Hub account and run %bdocker login%b, then retry.\n\n' "$CYAN" "$RESET"
  die "Docker image pull failed after $max_attempts attempts."
fi

ok "Docker images updated"

step "Step 3/4 — Restarting Services"
log "Restarting services"
docker compose --env-file "$ENV_FILE" up -d
ok "Services restarted"

step "Step 4/4 — Health Check"
log "Running health check"
"$PROJECT_DIR/scripts/healthcheck.sh" || true

# Final summary
printf '\n'
printf '%b┌──────────────────────────────────────────────┐%b\n' "$GREEN" "$RESET"
printf '%b│%b  ✓  Update Complete                          %b│%b\n' "$GREEN" "$BOLD$GREEN" "$GREEN" "$RESET"
printf '%b└──────────────────────────────────────────────┘%b\n' "$GREEN" "$RESET"
printf '\n'
