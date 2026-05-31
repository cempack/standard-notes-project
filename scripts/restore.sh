#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

PROJECT_DIR="${SN_PROJECT_DIR:-/opt/standardnotes}"
BACKUP_FILE="${1:-}"
WORKDIR=""

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

cleanup() { [[ -n "$WORKDIR" && -d "$WORKDIR" ]] && rm -rf "$WORKDIR"; }
trap cleanup EXIT

usage() {
  printf '\n'
  printf '%b┌──────────────────────────────────────────────┐%b\n' "$CYAN" "$RESET"
  printf '%b│%b  🔄  Standard Notes Restore                  %b│%b\n' "$CYAN" "$BOLD" "$CYAN" "$RESET"
  printf '%b└──────────────────────────────────────────────┘%b\n' "$CYAN" "$RESET"
  printf '\n'
  printf '  %bUsage:%b sudo %s /path/to/backup.tar.gz\n\n' "$BOLD" "$RESET" "$0"
  printf '  This overwrites the Standard Notes database, upload data,\n'
  printf '  and saved config in %b%s%b.\n' "$CYAN" "$PROJECT_DIR" "$RESET"
  printf '  A pre-restore snapshot of current config is saved first.\n\n'
}

[[ -n "$BACKUP_FILE" ]] || { usage; exit 1; }
[[ -f "$BACKUP_FILE" ]] || die "Backup file not found: $BACKUP_FILE"
command -v docker >/dev/null 2>&1 || die "Docker is not installed. Run install.sh first."

# Header
printf '\n'
printf '%b┌──────────────────────────────────────────────┐%b\n' "$CYAN" "$RESET"
printf '%b│%b  🔄  Standard Notes Restore                  %b│%b\n' "$CYAN" "$BOLD" "$CYAN" "$RESET"
printf '%b└──────────────────────────────────────────────┘%b\n' "$CYAN" "$RESET"
printf '\n'

step "Verifying Backup Archive"
if [[ -f "$BACKUP_FILE.sha256" ]]; then
  EXPECTED="$(awk '{print $1}' "$BACKUP_FILE.sha256" | head -n1)"
  ACTUAL="$(sha256sum "$BACKUP_FILE" | awk '{print $1}')"
  [[ "$EXPECTED" == "$ACTUAL" ]] || die "SHA256 verification failed. Expected $EXPECTED but got $ACTUAL"
  ok "SHA256 verification passed"
else
  warn "No .sha256 sidecar found; skipping checksum verification"
fi

WORKDIR="$(mktemp -d)"
tar -xzf "$BACKUP_FILE" -C "$WORKDIR"
[[ -f "$WORKDIR/mysql.sql" ]] || die "Backup archive does not contain mysql.sql"
ok "Archive extracted successfully"

printf '\n'
printf '%b┌──────────────────────────────────────────────────────────┐%b\n' "$RED" "$RESET"
printf '%b│%b                                                          %b│%b\n' "$RED" "$BOLD$RED" "$RED" "$RESET"
printf '%b│%b  ⚠  WARNING: This will overwrite Standard Notes data    %b│%b\n' "$RED" "$BOLD$RED" "$RED" "$RESET"
printf '%b│%b                                                          %b│%b\n' "$RED" "$BOLD$RED" "$RED" "$RESET"
printf '%b│%b  Target directory: %-36s  %b│%b\n' "$RED" "$RESET" "$PROJECT_DIR" "$RED" "$RESET"
printf '%b│%b                                                          %b│%b\n' "$RED" "$BOLD$RED" "$RED" "$RESET"
printf '%b│%b  The restore will overwrite:                             %b│%b\n' "$RED" "$RESET" "$RED" "$RESET"
printf '%b│%b    • MySQL database                                      %b│%b\n' "$RED" "$DIM" "$RED" "$RESET"
printf '%b│%b    • uploads/                                             %b│%b\n' "$RED" "$DIM" "$RED" "$RESET"
printf '%b│%b    • data/redis/                                          %b│%b\n' "$RED" "$DIM" "$RED" "$RESET"
printf '%b│%b    • Configuration files                                  %b│%b\n' "$RED" "$DIM" "$RED" "$RESET"
printf '%b│%b                                                          %b│%b\n' "$RED" "$BOLD$RED" "$RED" "$RESET"
printf '%b└──────────────────────────────────────────────────────────┘%b\n' "$RED" "$RESET"
printf '\n'
printf '  Type %bRESTORE%b to continue: ' "$BOLD$RED" "$RESET"
read -r CONFIRM
[[ "$CONFIRM" == "RESTORE" ]] || die "Restore cancelled."

step "Saving Pre-Restore Snapshot"
mkdir -p "$PROJECT_DIR"
PRE_RESTORE_DIR="$PROJECT_DIR/pre-restore-$(date -u +%Y%m%dT%H%M%SZ)"
mkdir -p "$PRE_RESTORE_DIR"
for file in .env .install-config docker-compose.yml localstack_bootstrap.sh; do
  [[ -f "$PROJECT_DIR/$file" ]] && cp -a "$PROJECT_DIR/$file" "$PRE_RESTORE_DIR/$file"
done
ok "Current config saved to $PRE_RESTORE_DIR"

step "Restoring Configuration"
if [[ -d "$WORKDIR/config" ]]; then
  [[ -f "$WORKDIR/config/.env" ]] && cp -a "$WORKDIR/config/.env" "$PROJECT_DIR/.env"
  [[ -f "$WORKDIR/config/docker-compose.yml" ]] && cp -a "$WORKDIR/config/docker-compose.yml" "$PROJECT_DIR/docker-compose.yml"
  [[ -f "$WORKDIR/config/localstack_bootstrap.sh" ]] && cp -a "$WORKDIR/config/localstack_bootstrap.sh" "$PROJECT_DIR/localstack_bootstrap.sh"
  [[ -f "$WORKDIR/config/.install-config" ]] && cp -a "$WORKDIR/config/.install-config" "$PROJECT_DIR/.install-config"
fi

[[ -f "$PROJECT_DIR/.env" ]] || die "No .env available after restore config step"
[[ -f "$PROJECT_DIR/docker-compose.yml" ]] || die "No docker-compose.yml available after restore config step"
chmod 600 "$PROJECT_DIR/.env" 2>/dev/null || true
chmod +x "$PROJECT_DIR/localstack_bootstrap.sh" 2>/dev/null || true
ok "Configuration files restored"

ENV_FILE="$PROJECT_DIR/.env"
COMPOSE=(docker compose -f "$PROJECT_DIR/docker-compose.yml" --env-file "$ENV_FILE")

step "Stopping Current Services"
log "Stopping current Standard Notes containers"
"${COMPOSE[@]}" down || true
ok "Services stopped"

MYSQL_PRE_RESTORE_DIR="$PROJECT_DIR/data/mysql.pre-restore-$(date -u +%Y%m%dT%H%M%SZ)"
if [[ -d "$PROJECT_DIR/data/mysql" ]] && find "$PROJECT_DIR/data/mysql" -mindepth 1 -maxdepth 1 -print -quit | grep -q .; then
  mv "$PROJECT_DIR/data/mysql" "$MYSQL_PRE_RESTORE_DIR"
  log "Moved existing MySQL data to $MYSQL_PRE_RESTORE_DIR"
fi

step "Restoring Data Files"
log "Restoring uploads and Redis data"
mkdir -p "$PROJECT_DIR/uploads" "$PROJECT_DIR/data/redis" "$PROJECT_DIR/data/mysql" "$PROJECT_DIR/data/import" "$PROJECT_DIR/logs"
if [[ -d "$WORKDIR/uploads" ]]; then
  rsync -a --delete "$WORKDIR/uploads/" "$PROJECT_DIR/uploads/"
fi
if [[ -d "$WORKDIR/data/redis" ]]; then
  rsync -a --delete "$WORKDIR/data/redis/" "$PROJECT_DIR/data/redis/"
fi
ok "Data files restored"

step "Restoring Database"
log "Starting database dependencies"
"${COMPOSE[@]}" up -d db cache localstack

wait_for_db() {
  for _ in {1..60}; do
    if docker exec db_self_hosted sh -c 'mysqladmin ping -uroot -p"$MYSQL_ROOT_PASSWORD" --silent' >/dev/null 2>&1; then
      return 0
    fi
    sleep 2
  done
  return 1
}
wait_for_db || die "MySQL did not become ready in time"
ok "Database is ready"

log "Dropping and recreating database"
docker exec db_self_hosted sh -c 'mysql -uroot -p"$MYSQL_ROOT_PASSWORD" -e "DROP DATABASE IF EXISTS \`$MYSQL_DATABASE\`; CREATE DATABASE \`$MYSQL_DATABASE\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;"'

log "Importing database dump"
docker exec -i db_self_hosted sh -c 'mysql -uroot -p"$MYSQL_ROOT_PASSWORD" "$MYSQL_DATABASE"' < "$WORKDIR/mysql.sql"
ok "Database imported successfully"

step "Starting All Services"
log "Starting all Standard Notes services"
"${COMPOSE[@]}" up -d
ok "All services started"

# Final summary
printf '\n'
printf '%b┌──────────────────────────────────────────────┐%b\n' "$GREEN" "$RESET"
printf '%b│%b  ✓  Restore Complete                         %b│%b\n' "$GREEN" "$BOLD$GREEN" "$GREEN" "$RESET"
printf '%b└──────────────────────────────────────────────┘%b\n' "$GREEN" "$RESET"
printf '\n'
printf '  %bNext step:%b Run the health checker:\n' "$BOLD" "$RESET"
printf '  %b$%b %bsudo %s/scripts/healthcheck.sh%b\n\n' "$DIM" "$RESET" "$CYAN" "$PROJECT_DIR" "$RESET"
