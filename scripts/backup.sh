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

log() { printf '[%s] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
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

log "Starting Standard Notes backup"
wait_for_db || die "MySQL container is not ready. Is Standard Notes running?"

WORKDIR="$(mktemp -d)"
mkdir -p "$WORKDIR/config" "$WORKDIR/uploads" "$WORKDIR/data/redis"

log "Dumping MySQL database"
"${COMPOSE[@]}" exec -T db sh -c 'mysqldump -uroot -p"$MYSQL_ROOT_PASSWORD" --single-transaction --routines --triggers --events "$MYSQL_DATABASE"' > "$WORKDIR/mysql.sql"

log "Copying uploads and persistent metadata"
mkdir -p "$PROJECT_DIR/uploads" "$PROJECT_DIR/data/redis"
rsync -a --delete "$PROJECT_DIR/uploads/" "$WORKDIR/uploads/"
rsync -a --delete "$PROJECT_DIR/data/redis/" "$WORKDIR/data/redis/"

cp -a "$ENV_FILE" "$WORKDIR/config/.env"
cp -a "$PROJECT_DIR/docker-compose.yml" "$WORKDIR/config/docker-compose.yml"
cp -a "$PROJECT_DIR/localstack_bootstrap.sh" "$WORKDIR/config/localstack_bootstrap.sh"
[[ -f "$PROJECT_DIR/.install-config" ]] && cp -a "$PROJECT_DIR/.install-config" "$WORKDIR/config/.install-config"

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

log "Creating compressed archive"
umask 077
tar -czf "$BACKUP_FILE" -C "$WORKDIR" .
SHA256="$(sha256sum "$BACKUP_FILE" | awk '{print $1}')"
printf '%s  %s\n' "$SHA256" "$(basename "$BACKUP_FILE")" > "$BACKUP_FILE.sha256"
chmod 600 "$BACKUP_FILE" "$BACKUP_FILE.sha256"

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
fi

log "Backup complete: $BACKUP_FILE"
log "SHA256: $SHA256"
