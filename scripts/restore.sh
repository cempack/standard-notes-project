#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

PROJECT_DIR="${SN_PROJECT_DIR:-/opt/standardnotes}"
BACKUP_FILE="${1:-}"
WORKDIR=""

log() { printf '[%s] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
cleanup() { [[ -n "$WORKDIR" && -d "$WORKDIR" ]] && rm -rf "$WORKDIR"; }
trap cleanup EXIT

usage() {
  cat <<USAGE
Usage: sudo $0 /path/to/standardnotes-backup-YYYYmmddTHHMMSSZ.tar.gz

This restore overwrites the Standard Notes database, upload data, and saved config
in $PROJECT_DIR. It creates a small pre-restore copy of current config first.
USAGE
}

[[ -n "$BACKUP_FILE" ]] || { usage; exit 1; }
[[ -f "$BACKUP_FILE" ]] || die "Backup file not found: $BACKUP_FILE"
command -v docker >/dev/null 2>&1 || die "Docker is not installed. Run install.sh first."

if [[ -f "$BACKUP_FILE.sha256" ]]; then
  EXPECTED="$(awk '{print $1}' "$BACKUP_FILE.sha256" | head -n1)"
  ACTUAL="$(sha256sum "$BACKUP_FILE" | awk '{print $1}')"
  [[ "$EXPECTED" == "$ACTUAL" ]] || die "SHA256 verification failed. Expected $EXPECTED but got $ACTUAL"
  log "SHA256 verification passed"
else
  log "No .sha256 sidecar found; skipping checksum verification"
fi

WORKDIR="$(mktemp -d)"
tar -xzf "$BACKUP_FILE" -C "$WORKDIR"
[[ -f "$WORKDIR/mysql.sql" ]] || die "Backup archive does not contain mysql.sql"

cat <<WARNING

WARNING: This will overwrite the Standard Notes data in:
  $PROJECT_DIR

It will restore:
  - MySQL database
  - uploads/
  - data/redis/
  - config files from the backup when present

Type RESTORE to continue.
WARNING
read -r -p "> " CONFIRM
[[ "$CONFIRM" == "RESTORE" ]] || die "Restore cancelled."

mkdir -p "$PROJECT_DIR"
PRE_RESTORE_DIR="$PROJECT_DIR/pre-restore-$(date -u +%Y%m%dT%H%M%SZ)"
mkdir -p "$PRE_RESTORE_DIR"
for file in .env .install-config docker-compose.yml localstack_bootstrap.sh; do
  [[ -f "$PROJECT_DIR/$file" ]] && cp -a "$PROJECT_DIR/$file" "$PRE_RESTORE_DIR/$file"
done
log "Saved current config snapshot to $PRE_RESTORE_DIR"

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

ENV_FILE="$PROJECT_DIR/.env"
COMPOSE=(docker compose -f "$PROJECT_DIR/docker-compose.yml" --env-file "$ENV_FILE")

log "Stopping current Standard Notes containers"
"${COMPOSE[@]}" down || true

MYSQL_PRE_RESTORE_DIR="$PROJECT_DIR/data/mysql.pre-restore-$(date -u +%Y%m%dT%H%M%SZ)"
if [[ -d "$PROJECT_DIR/data/mysql" ]] && find "$PROJECT_DIR/data/mysql" -mindepth 1 -maxdepth 1 -print -quit | grep -q .; then
  mv "$PROJECT_DIR/data/mysql" "$MYSQL_PRE_RESTORE_DIR"
  log "Moved existing MySQL data directory to $MYSQL_PRE_RESTORE_DIR so the restored .env password can initialize a clean database"
fi

log "Restoring uploads and Redis data"
mkdir -p "$PROJECT_DIR/uploads" "$PROJECT_DIR/data/redis" "$PROJECT_DIR/data/mysql" "$PROJECT_DIR/data/import" "$PROJECT_DIR/logs"
if [[ -d "$WORKDIR/uploads" ]]; then
  rsync -a --delete "$WORKDIR/uploads/" "$PROJECT_DIR/uploads/"
fi
if [[ -d "$WORKDIR/data/redis" ]]; then
  rsync -a --delete "$WORKDIR/data/redis/" "$PROJECT_DIR/data/redis/"
fi

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

log "Dropping and recreating restored database"
docker exec db_self_hosted sh -c 'mysql -uroot -p"$MYSQL_ROOT_PASSWORD" -e "DROP DATABASE IF EXISTS \`$MYSQL_DATABASE\`; CREATE DATABASE \`$MYSQL_DATABASE\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;"'

log "Importing database dump"
docker exec -i db_self_hosted sh -c 'mysql -uroot -p"$MYSQL_ROOT_PASSWORD" "$MYSQL_DATABASE"' < "$WORKDIR/mysql.sql"

log "Starting all Standard Notes services"
"${COMPOSE[@]}" up -d

log "Restore complete. Run: $PROJECT_DIR/scripts/healthcheck.sh"
