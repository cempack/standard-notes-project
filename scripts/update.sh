#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

PROJECT_DIR="${SN_PROJECT_DIR:-/opt/standardnotes}"
ENV_FILE="$PROJECT_DIR/.env"

log() { printf '[%s] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

[[ -f "$ENV_FILE" ]] || die "Missing $ENV_FILE. Run install.sh first."
[[ -f "$PROJECT_DIR/docker-compose.yml" ]] || die "Missing docker-compose.yml in $PROJECT_DIR"

cat <<INFO
This will:
  1. Run a backup.
  2. Pull the latest Standard Notes, MySQL, Redis, and LocalStack images.
  3. Recreate containers with docker compose up -d.

INFO
read -r -p "Continue? [y/N] " ANSWER
case "$ANSWER" in
  y|Y|yes|YES) ;;
  *) die "Update cancelled." ;;
esac

log "Running pre-update backup"
SN_PROJECT_DIR="$PROJECT_DIR" "$PROJECT_DIR/scripts/backup.sh"

log "Pulling Docker images"
cd "$PROJECT_DIR"
docker compose --env-file "$ENV_FILE" pull

log "Restarting services"
docker compose --env-file "$ENV_FILE" up -d

log "Running health check"
"$PROJECT_DIR/scripts/healthcheck.sh" || true

log "Update complete"
