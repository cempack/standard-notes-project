#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

PROJECT_DIR="${SN_PROJECT_DIR:-/opt/standardnotes}"
BACKUP_DIR="${SN_BACKUP_DIR:-$PROJECT_DIR/backups}"
RETENTION_DAYS="${SN_BACKUP_RETENTION_DAYS:-14}"
ENV_FILE="$PROJECT_DIR/.env"
TIMESTAMP="$(date -u +%Y%m%dT%H%M%SZ)"
BACKUP_FILE="$BACKUP_DIR/standardnotes-backup-$TIMESTAMP.tar.gz"
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

[[ -d "$PROJECT_DIR" ]] || die "Project directory not found: $PROJECT_DIR"
[[ -f "$ENV_FILE" ]] || die "Missing $ENV_FILE. Run install.sh first."
[[ -f "$PROJECT_DIR/docker-compose.yml" ]] || die "Missing docker-compose.yml in $PROJECT_DIR"

mkdir -p "$BACKUP_DIR"
chmod 700 "$BACKUP_DIR"

LOCK_FILE="$BACKUP_DIR/.backup.lock"
exec 9>"$LOCK_FILE"
flock -n 9 || die "Another backup is already running."

COMPOSE=(docker compose -f "$PROJECT_DIR/docker-compose.yml" --env-file "$ENV_FILE")

wait_for_db() {
  for _ in {1..45}; do
    if docker exec db_self_hosted sh -c 'mysqladmin ping -uroot -p"$MYSQL_ROOT_PASSWORD" --silent' >/dev/null 2>&1; then
      return 0
    fi
    sleep 2
  done
  return 1
}

# Header
printf '\n'
printf '%b┌──────────────────────────────────────────────┐%b\n' "$CYAN" "$RESET"
printf '%b│%b  📦  Standard Notes Backup                   %b│%b\n' "$CYAN" "$BOLD" "$CYAN" "$RESET"
printf '%b└──────────────────────────────────────────────┘%b\n' "$CYAN" "$RESET"
printf '\n'

step "Preparing Backup"
log "Starting Standard Notes backup"
log "Target: $BACKUP_FILE"
log "Retention: ${RETENTION_DAYS} days"

if type with_spinner &>/dev/null; then
  with_spinner "Waiting for database" wait_for_db
else
  wait_for_db || die "MySQL container is not ready. Is Standard Notes running?"
fi
ok "Database is ready"

WORKDIR="$(mktemp -d)"
mkdir -p "$WORKDIR/config" "$WORKDIR/uploads" "$WORKDIR/data/redis"

step "Dumping Database"
log "Dumping MySQL database"
"${COMPOSE[@]}" exec -T db sh -c 'mysqldump -uroot -p"$MYSQL_ROOT_PASSWORD" --single-transaction --routines --triggers --events "$MYSQL_DATABASE"' > "$WORKDIR/mysql.sql"
ok "MySQL dump complete"

step "Copying Data"
log "Copying uploads and persistent metadata"
mkdir -p "$PROJECT_DIR/uploads" "$PROJECT_DIR/data/redis"
rsync -a --delete "$PROJECT_DIR/uploads/" "$WORKDIR/uploads/"
rsync -a --delete "$PROJECT_DIR/data/redis/" "$WORKDIR/data/redis/"
ok "Uploads and Redis data copied"

log "Copying configuration files"
cp -a "$ENV_FILE" "$WORKDIR/config/.env"
cp -a "$PROJECT_DIR/docker-compose.yml" "$WORKDIR/config/docker-compose.yml"
cp -a "$PROJECT_DIR/localstack_bootstrap.sh" "$WORKDIR/config/localstack_bootstrap.sh"
[[ -f "$PROJECT_DIR/.install-config" ]] && cp -a "$PROJECT_DIR/.install-config" "$WORKDIR/config/.install-config"
ok "Configuration files copied"

cat > "$WORKDIR/README-RESTORE.txt" <<'RESTOREINFO'
This archive was created by scripts/backup.sh from the Standard Notes self-hosting project.
Restore it with:

  sudo /opt/standardnotes/scripts/restore.sh /path/to/standardnotes-backup-YYYYmmddTHHMMSSZ.tar.gz

The archive contains:
- mysql.sql database dump
- uploads/ file upload data
- data/redis/ Redis persistence snapshot/cache data
- config/ .env, docker-compose.yml, localstack_bootstrap.sh, and optional .install-config
RESTOREINFO

step "Creating Archive"
log "Compressing backup archive"
umask 077
tar -czf "$BACKUP_FILE" -C "$WORKDIR" .
SHA256="$(sha256sum "$BACKUP_FILE" | awk '{print $1}')"
printf '%s  %s\n' "$SHA256" "$(basename "$BACKUP_FILE")" > "$BACKUP_FILE.sha256"
chmod 600 "$BACKUP_FILE" "$BACKUP_FILE.sha256"
ok "Archive created"

SIZE_BYTES="$(stat -c%s "$BACKUP_FILE")"
HOSTNAME_FQDN="$(hostname -f 2>/dev/null || hostname)"
cat > "$BACKUP_DIR/LATEST.json" <<JSON
{
  "created_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "file": "$BACKUP_FILE",
  "sha256": "$SHA256",
  "size_bytes": $SIZE_BYTES,
  "hostname": "$HOSTNAME_FQDN"
}
JSON
chmod 640 "$BACKUP_DIR/LATEST.json"

if getent group sn-dashboard >/dev/null 2>&1; then
  chgrp sn-dashboard "$BACKUP_DIR" "$BACKUP_DIR/LATEST.json" 2>/dev/null || true
  chmod 750 "$BACKUP_DIR" 2>/dev/null || true
fi

if [[ "$RETENTION_DAYS" =~ ^[0-9]+$ && "$RETENTION_DAYS" -gt 0 ]]; then
  log "Pruning backups older than $RETENTION_DAYS days"
  find "$BACKUP_DIR" -maxdepth 1 -type f -name 'standardnotes-backup-*.tar.gz' -mtime +"$RETENTION_DAYS" -delete
  find "$BACKUP_DIR" -maxdepth 1 -type f -name 'standardnotes-backup-*.tar.gz.sha256' -mtime +"$RETENTION_DAYS" -delete
  ok "Old backups pruned"
fi

# Format size nicely
if (( SIZE_BYTES >= 1073741824 )); then
  SIZE_HUMAN="$(awk "BEGIN{printf \"%.1f GB\", $SIZE_BYTES/1073741824}")"
elif (( SIZE_BYTES >= 1048576 )); then
  SIZE_HUMAN="$(awk "BEGIN{printf \"%.1f MB\", $SIZE_BYTES/1048576}")"
elif (( SIZE_BYTES >= 1024 )); then
  SIZE_HUMAN="$(awk "BEGIN{printf \"%.1f KB\", $SIZE_BYTES/1024}")"
else
  SIZE_HUMAN="${SIZE_BYTES} B"
fi

# Final summary
printf '\n'
printf '%b┌──────────────────────────────────────────────┐%b\n' "$GREEN" "$RESET"
printf '%b│%b  ✓  Backup Complete                          %b│%b\n' "$GREEN" "$BOLD$GREEN" "$GREEN" "$RESET"
printf '%b└──────────────────────────────────────────────┘%b\n' "$GREEN" "$RESET"
printf '\n'
printf '  %bFile%b      %s\n' "$DIM" "$RESET" "$BACKUP_FILE"
printf '  %bSize%b      %s\n' "$DIM" "$RESET" "$SIZE_HUMAN"
printf '  %bSHA256%b    %s\n' "$DIM" "$RESET" "$SHA256"
printf '\n'
