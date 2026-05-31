#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

PROJECT_DIR="${SN_PROJECT_DIR:-/opt/standardnotes}"
EMAIL=""
WAIT_FOR_USER="no"
TIMEOUT_SECONDS=600
POLL_SECONDS=5

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

log()  { printf '%b   [%s]%b %s\n' "$DIM" "$(date -u +%H:%M:%S)" "$RESET" "$*"; }
step() { printf '\n%b━━━ ▸ %s ◂ ━━━%b\n' "$CYAN$BOLD" "$*" "$RESET"; }
ok()   { printf '%b  ✓%b %s\n' "$GREEN" "$RESET" "$*"; }
warn() { printf '%b  ⚠%b %s\n' "$YELLOW" "$RESET" "$*"; }
die()  { printf '%b  ✗%b %s\n' "$RED" "$RESET" "$*" >&2; exit 1; }

usage() {
  printf '\n'
  printf '%b┌──────────────────────────────────────────────┐%b\n' "$CYAN" "$RESET"
  printf '%b│%b  ⭐  Grant PRO Subscription                  %b│%b\n' "$CYAN" "$BOLD" "$CYAN" "$RESET"
  printf '%b└──────────────────────────────────────────────┘%b\n' "$CYAN" "$RESET"
  printf '\n'
  printf '  %bUsage:%b sudo %s [--wait] [--timeout SECONDS] EMAIL\n\n' "$BOLD" "$RESET" "$0"
  printf '  Grants server-side %bPRO_USER%b role and %bPRO_PLAN%b subscription\n' "$CYAN$BOLD" "$RESET" "$CYAN$BOLD" "$RESET"
  printf '  to an existing Standard Notes account.\n\n'
  printf '  %bOptions:%b\n' "$BOLD" "$RESET"
  printf '    %b--wait%b              Poll database until account appears\n' "$CYAN" "$RESET"
  printf '    %b--timeout SECONDS%b   Max wait time (default: 600)\n' "$CYAN" "$RESET"
  printf '    %b--poll SECONDS%b      Poll interval (default: 5)\n\n' "$CYAN" "$RESET"
  printf '  %b⚠  Important:%b\n' "$YELLOW" "$RESET"
  printf '    %b•%b Account must exist unless --wait is used\n' "$DIM" "$RESET"
  printf '    %b•%b This unlocks server-side premium features only\n' "$DIM" "$RESET"
  printf '    %b•%b Client-side features (Super notes, Nested tags)\n' "$DIM" "$RESET"
  printf '      require an offline plan\n\n'
}

while [[ "$#" -gt 0 ]]; do
  case "$1" in
    -h|--help)
      usage
      exit 0
      ;;
    --wait)
      WAIT_FOR_USER="yes"
      shift
      ;;
    --timeout)
      [[ -n "${2:-}" ]] || die "--timeout requires a number of seconds"
      TIMEOUT_SECONDS="$2"
      shift 2
      ;;
    --poll)
      [[ -n "${2:-}" ]] || die "--poll requires a number of seconds"
      POLL_SECONDS="$2"
      shift 2
      ;;
    --)
      shift
      break
      ;;
    -*)
      die "Unknown option: $1"
      ;;
    *)
      if [[ -n "$EMAIL" ]]; then
        die "Only one email address may be provided"
      fi
      EMAIL="$1"
      shift
      ;;
  esac
done

if [[ -z "$EMAIL" ]]; then
  printf '  %b❯%b Account email to grant PRO_PLAN to: ' "$CYAN" "$RESET"
  read -r EMAIL
fi

[[ "$TIMEOUT_SECONDS" =~ ^[0-9]+$ ]] || die "--timeout must be a number of seconds"
[[ "$POLL_SECONDS" =~ ^[0-9]+$ ]] || die "--poll must be a number of seconds"
[[ "$POLL_SECONDS" -gt 0 ]] || die "--poll must be greater than zero"

# Keep the validation intentionally strict. The email is interpolated into SQL,
# so do not permit quotes, spaces, semicolons, or unusual shell/SQL metacharacters.
if [[ ! "$EMAIL" =~ ^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]]; then
  die "Invalid email format or unsupported characters: $EMAIL"
fi

[[ -d "$PROJECT_DIR" ]] || die "Project directory not found: $PROJECT_DIR"
[[ -f "$PROJECT_DIR/docker-compose.yml" ]] || die "Missing $PROJECT_DIR/docker-compose.yml"
[[ -f "$PROJECT_DIR/.env" ]] || die "Missing $PROJECT_DIR/.env. Run install.sh first."
command -v docker >/dev/null 2>&1 || die "Docker is not installed or not in PATH."

# Header
printf '\n'
printf '%b┌──────────────────────────────────────────────┐%b\n' "$CYAN" "$RESET"
printf '%b│%b  ⭐  Grant PRO Subscription                  %b│%b\n' "$CYAN" "$BOLD" "$CYAN" "$RESET"
printf '%b└──────────────────────────────────────────────┘%b\n' "$CYAN" "$RESET"
printf '\n'
printf '  %bTarget:%b %s\n\n' "$DIM" "$RESET" "$EMAIL"

COMPOSE=(docker compose -f "$PROJECT_DIR/docker-compose.yml" --env-file "$PROJECT_DIR/.env")

wait_for_db() {
  for _ in {1..45}; do
    if docker exec db_self_hosted sh -c 'mysqladmin ping -uroot -p"$MYSQL_ROOT_PASSWORD" --silent' >/dev/null 2>&1; then
      return 0
    fi
    sleep 2
  done
  return 1
}

mysql_scalar() {
  "${COMPOSE[@]}" exec -T db sh -c 'MYSQL_PWD="$MYSQL_ROOT_PASSWORD" mysql -N -B "$MYSQL_DATABASE"' "$@"
}

mysql_exec() {
  "${COMPOSE[@]}" exec -T db sh -c 'MYSQL_PWD="$MYSQL_ROOT_PASSWORD" mysql "$MYSQL_DATABASE"' "$@"
}

step "Checking Database"
log "Checking database readiness"
wait_for_db || die "MySQL container is not ready. Is Standard Notes running?"
ok "Database is ready"

find_user_uuid() {
  mysql_scalar <<SQL
SELECT uuid FROM users WHERE email='${EMAIL}' LIMIT 1;
SQL
}

USER_UUID="$(find_user_uuid)"
if [[ -z "$USER_UUID" && "$WAIT_FOR_USER" == "yes" ]]; then
  step "Waiting for Account"
  log "Waiting up to ${TIMEOUT_SECONDS}s for account $EMAIL"
  START_SECONDS="$(date +%s)"
  while [[ -z "$USER_UUID" ]]; do
    NOW_SECONDS="$(date +%s)"
    ELAPSED=$(( NOW_SECONDS - START_SECONDS ))
    if (( ELAPSED >= TIMEOUT_SECONDS )); then
      break
    fi
    # Show progress if available
    if type show_progress &>/dev/null; then
      show_progress "$ELAPSED" "$TIMEOUT_SECONDS" "Waiting for registration"
    fi
    sleep "$POLL_SECONDS"
    USER_UUID="$(find_user_uuid)"
  done
  if type show_progress &>/dev/null; then
    printf '\n'
  fi
fi

if [[ -z "$USER_UUID" ]]; then
  die "No Standard Notes user found with email $EMAIL. Register/login once first, then rerun this script or use --wait."
fi

ok "Found user: $EMAIL"
printf '  %bUUID:%b %s\n' "$DIM" "$RESET" "$USER_UUID"

ROLE_UUID="$(mysql_scalar <<'SQL'
SELECT uuid FROM roles WHERE name='PRO_USER' ORDER BY version DESC LIMIT 1;
SQL
)"

if [[ -z "$ROLE_UUID" ]]; then
  die "Could not find PRO_USER role in the database. Check that server migrations completed successfully."
fi

step "Granting PRO_PLAN"
log "Granting PRO_USER role and PRO_PLAN subscription to $EMAIL"
mysql_exec <<SQL
SET @target_email = '${EMAIL}';
SET @user_uuid = (SELECT uuid FROM users WHERE email=@target_email LIMIT 1);
SET @role_uuid = (SELECT uuid FROM roles WHERE name='PRO_USER' ORDER BY version DESC LIMIT 1);

INSERT INTO user_roles (role_uuid, user_uuid)
VALUES (@role_uuid, @user_uuid)
ON DUPLICATE KEY UPDATE role_uuid = VALUES(role_uuid);

INSERT INTO user_subscriptions
  (uuid, plan_name, ends_at, created_at, updated_at, user_uuid, subscription_id, subscription_type)
SELECT UUID(), 'PRO_PLAN', 8640000000000000, 0, 0, @user_uuid, 1, 'regular'
WHERE NOT EXISTS (
  SELECT 1 FROM user_subscriptions
  WHERE user_uuid=@user_uuid AND plan_name='PRO_PLAN'
);

UPDATE user_subscriptions
SET plan_name='PRO_PLAN', ends_at=8640000000000000, updated_at=0, subscription_type='regular'
WHERE user_uuid=@user_uuid AND plan_name='PRO_PLAN';

SELECT 'Granted subscription for' AS status, @target_email AS email, @user_uuid AS user_uuid;
SQL

# Final summary
printf '\n'
printf '%b┌──────────────────────────────────────────────┐%b\n' "$GREEN" "$RESET"
printf '%b│%b  ✓  PRO_PLAN Granted Successfully            %b│%b\n' "$GREEN" "$BOLD$GREEN" "$GREEN" "$RESET"
printf '%b└──────────────────────────────────────────────┘%b\n' "$GREEN" "$RESET"
printf '\n'
printf '  %bAccount:%b  %s\n' "$DIM" "$RESET" "$EMAIL"
printf '  %bPlan:%b     PRO_PLAN (server-side)\n' "$DIM" "$RESET"
printf '\n'
printf '  %b⚠%b  Restart your Standard Notes client if features\n' "$YELLOW" "$RESET"
printf '     don'\''t refresh immediately.\n'
printf '\n'
printf '  %bNote:%b This unlocks server-side premium features only.\n' "$DIM" "$RESET"
printf '  For client-side features (Super notes, Nested tags),\n'
printf '  use a Standard Notes offline plan.\n\n'
