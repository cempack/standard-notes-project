#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

PROJECT_DIR="${SN_PROJECT_DIR:-/opt/standardnotes}"
EMAIL=""
WAIT_FOR_USER="no"
TIMEOUT_SECONDS=600
POLL_SECONDS=5

log() { printf '[%s] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<USAGE
Usage: sudo $0 [--wait] [--timeout SECONDS] EMAIL@ADDR

Grants the Standard Notes self-hosted server-side PRO_USER role and PRO_PLAN
subscription to an existing account email.

Important:
  - The account must already exist on this self-hosted server unless --wait is used.
  - --wait polls the database until the account appears or the timeout expires.
  - This unlocks server-side premium features only.
  - It does not unlock client-side premium features such as Super notes or
    Nested tags in official clients. Use an offline plan for those.
USAGE
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
  read -r -p "Account email to grant PRO_PLAN to: " EMAIL
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

log "Checking database readiness"
wait_for_db || die "MySQL container is not ready. Is Standard Notes running?"

find_user_uuid() {
  mysql_scalar <<SQL
SELECT uuid FROM users WHERE email='${EMAIL}' LIMIT 1;
SQL
}

USER_UUID="$(find_user_uuid)"
if [[ -z "$USER_UUID" && "$WAIT_FOR_USER" == "yes" ]]; then
  log "Waiting up to ${TIMEOUT_SECONDS}s for Standard Notes account $EMAIL to appear"
  START_SECONDS="$(date +%s)"
  while [[ -z "$USER_UUID" ]]; do
    NOW_SECONDS="$(date +%s)"
    if (( NOW_SECONDS - START_SECONDS >= TIMEOUT_SECONDS )); then
      break
    fi
    sleep "$POLL_SECONDS"
    USER_UUID="$(find_user_uuid)"
  done
fi

if [[ -z "$USER_UUID" ]]; then
  die "No Standard Notes user found with email $EMAIL. Register/login once first, then rerun this script or use --wait."
fi

ROLE_UUID="$(mysql_scalar <<'SQL'
SELECT uuid FROM roles WHERE name='PRO_USER' ORDER BY version DESC LIMIT 1;
SQL
)"

if [[ -z "$ROLE_UUID" ]]; then
  die "Could not find PRO_USER role in the database. Check that server migrations completed successfully."
fi

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

log "Done. Restart or re-login your Standard Notes client if feature status does not refresh immediately."
cat <<NOTE

Note: This follows Standard Notes' self-hosted subscription guidance and unlocks
server-side premium features only. It does not unlock client-side premium
features such as Super notes or Nested tags. For full client-side premium
features, use a Standard Notes offline plan.
NOTE
