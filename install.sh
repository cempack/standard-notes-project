#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEFAULT_INSTALL_DIR="/opt/standardnotes"
NGINX_SITE_AVAILABLE="/etc/nginx/sites-available/standardnotes.conf"
NGINX_SITE_ENABLED="/etc/nginx/sites-enabled/standardnotes.conf"
DASHBOARD_ENV_FILE="/etc/standardnotes-dashboard.env"
DASHBOARD_HTPASSWD="/etc/nginx/standardnotes-dashboard.htpasswd"
DASHBOARD_SYSTEM_USER="sn-dashboard"
GENERATED_DASHBOARD_PASSWORD=""

if [[ -t 1 ]]; then
  RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; BOLD='\033[1m'; RESET='\033[0m'
else
  RED=''; GREEN=''; YELLOW=''; BLUE=''; BOLD=''; RESET=''
fi

say() { printf '%b\n' "$*"; }
step() { printf '\n%b==> %s%b\n' "$BLUE" "$*" "$RESET"; }
ok() { printf '%b[OK]%b %s\n' "$GREEN" "$RESET" "$*"; }
warn() { printf '%b[WARN]%b %s\n' "$YELLOW" "$RESET" "$*"; }
error() { printf '%b[ERROR]%b %s\n' "$RED" "$RESET" "$*" >&2; }
die() { error "$*"; exit 1; }

on_error() {
  local code=$?
  error "Installation failed near line $1 (exit code $code). Review the output above, fix the issue, and rerun ./install.sh."
  exit "$code"
}
trap 'on_error $LINENO' ERR

prompt_value() {
  local __var="$1" question="$2" default="${3:-}" answer
  if [[ -n "$default" ]]; then
    read -r -p "$question [$default]: " answer
    answer="${answer:-$default}"
  else
    read -r -p "$question: " answer
  fi
  printf -v "$__var" '%s' "$answer"
}

prompt_secret() {
  local __var="$1" question="$2" answer
  read -r -s -p "$question: " answer
  printf '\n'
  printf -v "$__var" '%s' "$answer"
}

confirm() {
  local question="$1" default="${2:-Y}" answer prompt
  if [[ "$default" =~ ^[Yy]$ ]]; then
    prompt="$question [Y/n]: "
  else
    prompt="$question [y/N]: "
  fi
  read -r -p "$prompt" answer
  answer="${answer:-$default}"
  case "$answer" in
    y|Y|yes|YES) return 0 ;;
    *) return 1 ;;
  esac
}

yn_default() {
  case "${1:-}" in
    yes|true|1|y|Y) printf 'Y' ;;
    no|false|0|n|N) printf 'N' ;;
    *) printf '%s' "${2:-Y}" ;;
  esac
}

bool_word() {
  case "${1:-}" in
    y|Y|yes|YES|true|TRUE|1) printf 'yes' ;;
    *) printf 'no' ;;
  esac
}

normalize_domain() {
  local d="$1"
  d="${d#https://}"
  d="${d#http://}"
  d="${d%%/*}"
  d="${d%.}"
  printf '%s' "$d"
}

gen_hex() { openssl rand -hex "$1"; }

read_key_value() {
  local file="$1" key="$2" line value
  [[ -f "$file" ]] || return 1
  line="$(grep -E "^${key}=" "$file" | tail -n1 || true)"
  [[ -n "$line" ]] || return 1
  value="${line#*=}"
  value="${value%$'\r'}"
  value="${value%\"}"; value="${value#\"}"
  value="${value%\'}"; value="${value#\'}"
  printf '%s' "$value"
}

write_shell_kv() {
  local key="$1" value="$2"
  printf '%s=%q\n' "$key" "$value"
}

password_sha256() {
  local salt="$1" password="$2"
  printf '%s' "${salt}:${password}" | sha256sum | awk '{print $1}'
}

render_standardnotes_template() {
  local src="$1" dest="$2"
  sed \
    -e "s#__NOTES_DOMAIN__#${NOTES_DOMAIN}#g" \
    -e "s#__FILES_DOMAIN__#${FILES_DOMAIN}#g" \
    -e "s#__NOTES_SSL_CERT__#${NOTES_SSL_CERT:-}#g" \
    -e "s#__NOTES_SSL_KEY__#${NOTES_SSL_KEY:-}#g" \
    -e "s#__FILES_SSL_CERT__#${FILES_SSL_CERT:-}#g" \
    -e "s#__FILES_SSL_KEY__#${FILES_SSL_KEY:-}#g" \
    "$src" > "$dest"
}

render_install_template() {
  local src="$1" dest="$2"
  sed \
    -e "s#__INSTALL_DIR__#${INSTALL_DIR}#g" \
    -e "s#__BACKUP_RETENTION_DAYS__#${BACKUP_RETENTION_DAYS}#g" \
    -e "s#__BACKUP_ON_CALENDAR__#${BACKUP_ON_CALENDAR}#g" \
    "$src" > "$dest"
}

require_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    say "This installer needs root privileges. Re-running with sudo..."
    exec sudo -E bash "$0" "$@"
  fi
}

check_ubuntu() {
  [[ -f /etc/os-release ]] || die "This installer targets Ubuntu. /etc/os-release was not found."
  # shellcheck disable=SC1091
  source /etc/os-release
  [[ "${ID:-}" == "ubuntu" ]] || die "This installer targets Ubuntu. Detected ID=${ID:-unknown}."
  ok "Detected Ubuntu ${VERSION_ID:-unknown}"
}

ask_config() {
  cat <<INTRO
${BOLD}Standard Notes self-hosted installer${RESET}

This will install Docker, Nginx, Certbot, Fail2ban, unattended security updates,
a local dashboard, and the official Standard Notes Docker Compose stack.

Firewall/cloud provider ports to open before continuing:
  - TCP ${BOLD}80${RESET}: Let's Encrypt HTTP validation and HTTP->HTTPS redirects
  - TCP ${BOLD}443${RESET}: Standard Notes API, files server, and dashboard over HTTPS
  - TCP ${BOLD}your SSH port${RESET}: so you do not lock yourself out

Do ${BOLD}not${RESET} expose 3000 or 3125 publicly. This project binds them to 127.0.0.1
and publishes them only through Nginx HTTPS.

INTRO

  prompt_value INSTALL_DIR "Install directory" "${INSTALL_DIR:-$DEFAULT_INSTALL_DIR}"
  INSTALL_DIR="${INSTALL_DIR%/}"
  [[ "$INSTALL_DIR" != *[[:space:]]* ]] || die "Install directory must not contain whitespace."

  local existing_config="$INSTALL_DIR/.install-config"
  if [[ -f "$existing_config" ]]; then
    say "Found existing config at $existing_config; using it as defaults."
    # shellcheck disable=SC1090
    source "$existing_config"
    INSTALL_DIR="${INSTALL_DIR%/}"
  fi

  prompt_value NOTES_DOMAIN "Notes/API domain (example: notes.example.com)" "${NOTES_DOMAIN:-notes.example.com}"
  NOTES_DOMAIN="$(normalize_domain "$NOTES_DOMAIN")"
  prompt_value FILES_DOMAIN "Files domain (example: files.example.com)" "${FILES_DOMAIN:-files.example.com}"
  FILES_DOMAIN="$(normalize_domain "$FILES_DOMAIN")"
  [[ -n "$NOTES_DOMAIN" && -n "$FILES_DOMAIN" ]] || die "Both domains are required."
  [[ "$NOTES_DOMAIN" != "$FILES_DOMAIN" ]] || die "Notes and files domains must be different."

  prompt_value ADMIN_EMAIL "Email for Let's Encrypt and security notices" "${ADMIN_EMAIL:-admin@$NOTES_DOMAIN}"
  prompt_value DASHBOARD_USER "Dashboard username" "${DASHBOARD_USER:-admin}"
  if [[ -f "$DASHBOARD_HTPASSWD" || -f "$DASHBOARD_ENV_FILE" ]]; then
    say "Dashboard password: leave blank to keep the existing password if the username is unchanged."
  else
    say "Dashboard password: leave blank to generate a strong random password."
  fi
  prompt_secret DASHBOARD_PASSWORD_INPUT "Dashboard password"

  local detected_ssh_port
  detected_ssh_port="$(awk 'tolower($1)=="port" {print $2; exit}' /etc/ssh/sshd_config 2>/dev/null || true)"
  prompt_value SSH_PORT "SSH port to allow in UFW" "${SSH_PORT:-${detected_ssh_port:-22}}"

  if confirm "Use Let's Encrypt trusted certificates now" "$(yn_default "${USE_LETSENCRYPT:-yes}" Y)"; then USE_LETSENCRYPT="yes"; else USE_LETSENCRYPT="no"; fi
  if [[ "$USE_LETSENCRYPT" == "yes" ]]; then
    if confirm "Use Let's Encrypt staging/test certificates" "$(yn_default "${CERTBOT_STAGING:-no}" N)"; then CERTBOT_STAGING="yes"; else CERTBOT_STAGING="no"; fi
  else
    CERTBOT_STAGING="no"
    warn "The installer will create temporary self-signed certificates. Standard Notes clients will not trust these for production use."
  fi

  if confirm "Enable unattended Ubuntu security updates" "$(yn_default "${ENABLE_AUTO_UPDATES:-yes}" Y)"; then ENABLE_AUTO_UPDATES="yes"; else ENABLE_AUTO_UPDATES="no"; fi
  if confirm "Configure and enable UFW firewall rules" "$(yn_default "${UFW_ENABLE:-yes}" Y)"; then UFW_ENABLE="yes"; else UFW_ENABLE="no"; fi

  local existing_disable_registration
  existing_disable_registration="$(read_key_value "$INSTALL_DIR/.env" AUTH_SERVER_DISABLE_USER_REGISTRATION || true)"
  if confirm "Disable new user registration now (choose No until your first account exists)" "$(yn_default "${DISABLE_USER_REGISTRATION:-${existing_disable_registration:-no}}" N)"; then DISABLE_USER_REGISTRATION="yes"; else DISABLE_USER_REGISTRATION="no"; fi

  if confirm "Install snctl management CLI to /usr/local/bin/snctl" "$(yn_default "${INSTALL_SNCTL:-yes}" Y)"; then INSTALL_SNCTL="yes"; else INSTALL_SNCTL="no"; fi

  if confirm "After services start, wait for your first account and grant server-side PRO_PLAN automatically" "$(yn_default "${RUN_FIRST_ACCOUNT_FLOW:-no}" N)"; then
    RUN_FIRST_ACCOUNT_FLOW="yes"
    prompt_value FIRST_ACCOUNT_EMAIL "Email address you will register in Standard Notes" "${FIRST_ACCOUNT_EMAIL:-}"
    [[ -n "$FIRST_ACCOUNT_EMAIL" ]] || die "First account email is required for the automatic first-account flow."
    DISABLE_USER_REGISTRATION="no"
    warn "Registration will stay open during install so you can create $FIRST_ACCOUNT_EMAIL. The CLI will ask whether to lock it after granting PRO_PLAN."
  else
    RUN_FIRST_ACCOUNT_FLOW="no"
    FIRST_ACCOUNT_EMAIL="${FIRST_ACCOUNT_EMAIL:-}"
  fi

  if [[ -n "${SUDO_USER:-}" && "${SUDO_USER}" != "root" ]]; then
    if confirm "Add ${SUDO_USER} to the docker group (optional, root-equivalent access)" "$(yn_default "${ADD_SUDO_USER_TO_DOCKER:-no}" N)"; then ADD_SUDO_USER_TO_DOCKER="yes"; else ADD_SUDO_USER_TO_DOCKER="no"; fi
  else
    ADD_SUDO_USER_TO_DOCKER="no"
  fi

  prompt_value BACKUP_RETENTION_DAYS "Backup retention in days" "${BACKUP_RETENTION_DAYS:-14}"
  prompt_value BACKUP_ON_CALENDAR "systemd backup schedule (OnCalendar)" "${BACKUP_ON_CALENDAR:-*-*-* 03:15:00}"
  if confirm "Run an initial backup after services start" "$(yn_default "${RUN_INITIAL_BACKUP:-yes}" Y)"; then RUN_INITIAL_BACKUP="yes"; else RUN_INITIAL_BACKUP="no"; fi

  cat <<SUMMARY

${BOLD}Install summary${RESET}
  Install dir:       $INSTALL_DIR
  Notes API:         https://$NOTES_DOMAIN -> 127.0.0.1:3000
  Files server:      https://$FILES_DOMAIN -> 127.0.0.1:3125
  Dashboard:         https://$NOTES_DOMAIN/dashboard/
  Public ports:      80/tcp, 443/tcp, plus SSH $SSH_PORT/tcp
  Private ports:     127.0.0.1:3000, 127.0.0.1:3125, 127.0.0.1:8090
  Let's Encrypt:     $USE_LETSENCRYPT (staging: $CERTBOT_STAGING)
  Auto-updates:      $ENABLE_AUTO_UPDATES
  UFW:               $UFW_ENABLE
  Registration lock: $DISABLE_USER_REGISTRATION
  snctl CLI:         $INSTALL_SNCTL
  First acct flow:   $RUN_FIRST_ACCOUNT_FLOW ${FIRST_ACCOUNT_EMAIL:+($FIRST_ACCOUNT_EMAIL)}
  Docker group:      $ADD_SUDO_USER_TO_DOCKER
  Backups:           $BACKUP_ON_CALENDAR, retention ${BACKUP_RETENTION_DAYS}d

SUMMARY
  confirm "Proceed" Y || exit 0
}

install_base_packages() {
  step "Installing base packages"
  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get install -y \
    apt-transport-https \
    ca-certificates \
    curl \
    gnupg \
    lsb-release \
    openssl \
    ufw \
    nginx \
    fail2ban \
    certbot \
    python3-certbot-nginx \
    apache2-utils \
    unattended-upgrades \
    apt-listchanges \
    rsync \
    tar \
    gzip \
    jq \
    cron \
    logrotate \
    util-linux \
    golang-go
  ok "Base packages installed"
}

install_docker() {
  step "Installing Docker Engine and Compose plugin"
  if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
    ok "Docker and docker compose are already installed"
    systemctl enable --now docker
  else
    install -m 0755 -d /etc/apt/keyrings
    if [[ ! -f /etc/apt/keyrings/docker.gpg ]]; then
      curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --batch --yes --dearmor -o /etc/apt/keyrings/docker.gpg
      chmod a+r /etc/apt/keyrings/docker.gpg
    fi
    # shellcheck disable=SC1091
    source /etc/os-release
    local codename arch
    codename="${VERSION_CODENAME:-$(lsb_release -cs)}"
    arch="$(dpkg --print-architecture)"
    printf 'deb [arch=%s signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu %s stable\n' "$arch" "$codename" > /etc/apt/sources.list.d/docker.list
    apt-get update
    apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
    systemctl enable --now docker
    ok "Docker installed"
  fi

  if [[ "$ADD_SUDO_USER_TO_DOCKER" == "yes" && -n "${SUDO_USER:-}" && "${SUDO_USER}" != "root" ]]; then
    usermod -aG docker "$SUDO_USER" || true
    warn "Added $SUDO_USER to the docker group. Docker group membership is root-equivalent; log out and back in for it to apply."
  fi
}

copy_project_files() {
  step "Copying project files to $INSTALL_DIR"
  mkdir -p "$INSTALL_DIR"
  if [[ "$REPO_DIR" != "$INSTALL_DIR" ]]; then
    rsync -a \
      --exclude '.git' \
      --exclude '.env' \
      --exclude '.env.bak.*' \
      --exclude '.install-config' \
      --exclude 'data' \
      --exclude 'uploads' \
      --exclude 'logs' \
      --exclude 'backups/*' \
      "$REPO_DIR/" "$INSTALL_DIR/"
  fi
  mkdir -p "$INSTALL_DIR/data/mysql" "$INSTALL_DIR/data/import" "$INSTALL_DIR/data/redis" "$INSTALL_DIR/logs" "$INSTALL_DIR/uploads" "$INSTALL_DIR/backups"
  chmod +x "$INSTALL_DIR/install.sh" "$INSTALL_DIR/localstack_bootstrap.sh" "$INSTALL_DIR"/scripts/*.sh "$INSTALL_DIR/scripts/snctl"
  chmod 700 "$INSTALL_DIR/backups"
  ok "Project files ready"
}

write_install_config() {
  step "Writing installer config"
  {
    write_shell_kv INSTALL_DIR "$INSTALL_DIR"
    write_shell_kv NOTES_DOMAIN "$NOTES_DOMAIN"
    write_shell_kv FILES_DOMAIN "$FILES_DOMAIN"
    write_shell_kv ADMIN_EMAIL "$ADMIN_EMAIL"
    write_shell_kv DASHBOARD_USER "$DASHBOARD_USER"
    write_shell_kv SSH_PORT "$SSH_PORT"
    write_shell_kv USE_LETSENCRYPT "$USE_LETSENCRYPT"
    write_shell_kv CERTBOT_STAGING "$CERTBOT_STAGING"
    write_shell_kv ENABLE_AUTO_UPDATES "$ENABLE_AUTO_UPDATES"
    write_shell_kv UFW_ENABLE "$UFW_ENABLE"
    write_shell_kv DISABLE_USER_REGISTRATION "$DISABLE_USER_REGISTRATION"
    write_shell_kv INSTALL_SNCTL "$INSTALL_SNCTL"
    write_shell_kv RUN_FIRST_ACCOUNT_FLOW "$RUN_FIRST_ACCOUNT_FLOW"
    write_shell_kv FIRST_ACCOUNT_EMAIL "$FIRST_ACCOUNT_EMAIL"
    write_shell_kv ADD_SUDO_USER_TO_DOCKER "$ADD_SUDO_USER_TO_DOCKER"
    write_shell_kv BACKUP_RETENTION_DAYS "$BACKUP_RETENTION_DAYS"
    write_shell_kv BACKUP_ON_CALENDAR "$BACKUP_ON_CALENDAR"
    write_shell_kv RUN_INITIAL_BACKUP "$RUN_INITIAL_BACKUP"
  } > "$INSTALL_DIR/.install-config"
  chmod 600 "$INSTALL_DIR/.install-config"
  ok "Saved $INSTALL_DIR/.install-config"
}

write_env_file() {
  step "Writing Standard Notes .env"
  local env_file="$INSTALL_DIR/.env"
  local db_password auth_jwt auth_enc valet extra known_re backup_file disable_registration_value

  db_password="$(read_key_value "$env_file" DB_PASSWORD || true)"
  auth_jwt="$(read_key_value "$env_file" AUTH_JWT_SECRET || true)"
  auth_enc="$(read_key_value "$env_file" AUTH_SERVER_ENCRYPTION_SERVER_KEY || true)"
  valet="$(read_key_value "$env_file" VALET_TOKEN_SECRET || true)"

  [[ -n "$db_password" ]] || db_password="$(gen_hex 24)"
  [[ -n "$auth_jwt" ]] || auth_jwt="$(gen_hex 32)"
  [[ -n "$auth_enc" ]] || auth_enc="$(gen_hex 32)"
  [[ -n "$valet" ]] || valet="$(gen_hex 32)"

  known_re='^(DB_HOST|DB_PORT|DB_USERNAME|DB_PASSWORD|DB_DATABASE|DB_TYPE|REDIS_PORT|REDIS_HOST|CACHE_TYPE|AUTH_JWT_SECRET|AUTH_SERVER_ENCRYPTION_SERVER_KEY|VALET_TOKEN_SECRET|AUTH_SERVER_DISABLE_USER_REGISTRATION|PUBLIC_FILES_SERVER_URL)='
  extra=""
  if [[ -f "$env_file" ]]; then
    backup_file="$env_file.bak.$(date -u +%Y%m%dT%H%M%SZ)"
    cp -a "$env_file" "$backup_file"
    warn "Existing .env backed up to $backup_file"
    extra="$(grep -Ev "$known_re" "$env_file" || true)"
  fi

  disable_registration_value="false"
  [[ "$DISABLE_USER_REGISTRATION" == "yes" ]] && disable_registration_value="true"

  cat > "$env_file" <<EOF
# Generated by install.sh. Keep this file private.

######
# DB #
######
DB_HOST=db
DB_PORT=3306
DB_USERNAME=std_notes_user
DB_PASSWORD=$db_password
DB_DATABASE=standard_notes_db
DB_TYPE=mysql

#########
# CACHE #
#########
REDIS_PORT=6379
REDIS_HOST=cache
CACHE_TYPE=redis

########
# KEYS #
########
AUTH_JWT_SECRET=$auth_jwt
AUTH_SERVER_ENCRYPTION_SERVER_KEY=$auth_enc
VALET_TOKEN_SECRET=$valet

########
# AUTH #
########
# Keep false until your first account is registered, then set true and restart.
AUTH_SERVER_DISABLE_USER_REGISTRATION=$disable_registration_value

#########
# FILES #
#########
PUBLIC_FILES_SERVER_URL=https://$FILES_DOMAIN
EOF

  if [[ -n "$extra" ]]; then
    {
      printf '\n# Preserved custom entries from previous .env:\n'
      printf '%s\n' "$extra"
    } >> "$env_file"
  fi

  chmod 600 "$env_file"
  ok "Wrote $env_file with DB_PASSWORD and PUBLIC_FILES_SERVER_URL=https://$FILES_DOMAIN"
}

configure_auto_updates() {
  if [[ "$ENABLE_AUTO_UPDATES" != "yes" ]]; then
    warn "Unattended Ubuntu security updates not enabled by this installer."
    return
  fi
  step "Configuring unattended Ubuntu security updates"
  cp "$INSTALL_DIR/configs/unattended-upgrades/52standardnotes-unattended-upgrades" /etc/apt/apt.conf.d/52standardnotes-unattended-upgrades
  cat > /etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Download-Upgradeable-Packages "1";
APT::Periodic::AutocleanInterval "7";
APT::Periodic::Unattended-Upgrade "1";
EOF
  systemctl enable --now unattended-upgrades >/dev/null 2>&1 || true
  ok "Unattended security updates configured"
}

configure_logrotate() {
  step "Configuring log rotation"
  render_install_template "$INSTALL_DIR/configs/logrotate/standardnotes" /etc/logrotate.d/standardnotes
  ok "Logrotate configuration installed"
}

configure_firewall() {
  if [[ "$UFW_ENABLE" != "yes" ]]; then
    warn "UFW was not enabled by this installer. Ensure your host/cloud firewall allows TCP 80, 443, and SSH $SSH_PORT."
    return
  fi

  step "Configuring UFW firewall"
  ufw default deny incoming
  ufw default allow outgoing
  ufw allow "$SSH_PORT/tcp" comment 'SSH'
  ufw allow 80/tcp comment 'HTTP for ACME and redirect'
  ufw allow 443/tcp comment 'HTTPS for Standard Notes'
  ufw --force enable
  ufw status verbose || true
  ok "UFW configured. Ports 3000 and 3125 remain localhost-only and are not opened."
}

install_dashboard() {
  step "Building and installing dashboard"

  if ! id -u "$DASHBOARD_SYSTEM_USER" >/dev/null 2>&1; then
    useradd --system --create-home --home-dir /var/lib/standardnotes-dashboard --shell /usr/sbin/nologin --groups adm "$DASHBOARD_SYSTEM_USER"
  else
    usermod -aG adm "$DASHBOARD_SYSTEM_USER" || true
  fi
  install -d -o "$DASHBOARD_SYSTEM_USER" -g "$DASHBOARD_SYSTEM_USER" -m 0750 /var/lib/standardnotes-dashboard

  local existing_user existing_salt existing_hash effective_password salt hash
  existing_user="$(read_key_value "$DASHBOARD_ENV_FILE" SN_DASHBOARD_USER || true)"
  existing_salt="$(read_key_value "$DASHBOARD_ENV_FILE" SN_DASHBOARD_PASSWORD_SALT || true)"
  existing_hash="$(read_key_value "$DASHBOARD_ENV_FILE" SN_DASHBOARD_PASSWORD_SHA256 || true)"
  effective_password=""

  if [[ -n "$DASHBOARD_PASSWORD_INPUT" ]]; then
    effective_password="$DASHBOARD_PASSWORD_INPUT"
  elif [[ -n "$existing_salt" && -n "$existing_hash" && "$DASHBOARD_USER" == "$existing_user" && -f "$DASHBOARD_HTPASSWD" ]]; then
    salt="$existing_salt"
    hash="$existing_hash"
  else
    effective_password="$(gen_hex 12)"
    GENERATED_DASHBOARD_PASSWORD="$effective_password"
  fi

  if [[ -n "$effective_password" ]]; then
    salt="$(gen_hex 16)"
    hash="$(password_sha256 "$salt" "$effective_password")"
    printf '%s\n' "$effective_password" | htpasswd -iB -c "$DASHBOARD_HTPASSWD" "$DASHBOARD_USER" >/dev/null
    chown root:www-data "$DASHBOARD_HTPASSWD"
    chmod 640 "$DASHBOARD_HTPASSWD"
  fi

  cat > "$DASHBOARD_ENV_FILE" <<EOF
SN_DASHBOARD_ADDR=127.0.0.1:8090
SN_DASHBOARD_USER=$DASHBOARD_USER
SN_DASHBOARD_PASSWORD_SALT=$salt
SN_DASHBOARD_PASSWORD_SHA256=$hash
SN_DASHBOARD_API_URL=http://127.0.0.1:3000
SN_DASHBOARD_FILES_URL=http://127.0.0.1:3125
SN_DASHBOARD_NOTES_HTTPS=https://$NOTES_DOMAIN
SN_DASHBOARD_FILES_HTTPS=https://$FILES_DOMAIN
SN_PROJECT_DIR=$INSTALL_DIR
SN_BACKUP_DIR=$INSTALL_DIR/backups
SN_DASHBOARD_LOG_FILES=/var/log/nginx/standardnotes-error.log,/var/log/nginx/standardnotes-files-error.log,/var/log/nginx/standardnotes-access.log,$INSTALL_DIR/logs/*.err,$INSTALL_DIR/logs/*.log
EOF
  chown root:"$DASHBOARD_SYSTEM_USER" "$DASHBOARD_ENV_FILE"
  chmod 640 "$DASHBOARD_ENV_FILE"

  (cd "$INSTALL_DIR/dashboard" && go build -trimpath -ldflags='-s -w' -o dashboard .)
  chown root:root "$INSTALL_DIR/dashboard/dashboard"
  chmod 755 "$INSTALL_DIR/dashboard/dashboard"

  chgrp -R "$DASHBOARD_SYSTEM_USER" "$INSTALL_DIR/backups" 2>/dev/null || true
  chmod 750 "$INSTALL_DIR/backups" 2>/dev/null || true
  chgrp -R adm "$INSTALL_DIR/logs" 2>/dev/null || true
  chmod -R g+rX "$INSTALL_DIR/logs" 2>/dev/null || true

  render_install_template "$INSTALL_DIR/systemd/standardnotes-dashboard.service.template" /etc/systemd/system/standardnotes-dashboard.service
  systemctl daemon-reload
  systemctl enable --now standardnotes-dashboard
  systemctl restart standardnotes-dashboard
  ok "Dashboard service installed on 127.0.0.1:8090"
}

create_self_signed_cert() {
  local domain="$1" safe cert_dir cert key
  cert_dir="/etc/ssl/standardnotes"
  safe="${domain//[^A-Za-z0-9_.-]/_}"
  cert="$cert_dir/$safe.crt"
  key="$cert_dir/$safe.key"
  install -d -m 0755 "$cert_dir"
  if [[ ! -f "$cert" || ! -f "$key" ]]; then
    openssl req -x509 -nodes -newkey rsa:4096 -sha256 -days 30 \
      -keyout "$key" \
      -out "$cert" \
      -subj "/CN=$domain" \
      -addext "subjectAltName=DNS:$domain"
    chmod 600 "$key"
  fi
  printf '%s|%s' "$cert" "$key"
}

obtain_letsencrypt_cert() {
  local domain="$1"
  local args=(certonly --webroot -w /var/www/letsencrypt -d "$domain" --email "$ADMIN_EMAIL" --agree-tos --non-interactive --keep-until-expiring)
  [[ "$CERTBOT_STAGING" == "yes" ]] && args+=(--staging)
  certbot "${args[@]}"
}

configure_nginx() {
  step "Configuring Nginx and HTTPS"
  install -d -m 0755 /var/www/letsencrypt
  chown www-data:www-data /var/www/letsencrypt

  render_standardnotes_template "$INSTALL_DIR/nginx/standardnotes-http.conf.template" "$NGINX_SITE_AVAILABLE"
  ln -sf "$NGINX_SITE_AVAILABLE" "$NGINX_SITE_ENABLED"
  [[ -L /etc/nginx/sites-enabled/default ]] && rm -f /etc/nginx/sites-enabled/default
  nginx -t
  systemctl enable --now nginx
  systemctl reload nginx

  if [[ "$USE_LETSENCRYPT" == "yes" ]]; then
    [[ -n "$ADMIN_EMAIL" ]] || die "Let's Encrypt requires an email address."
    say "Requesting Let's Encrypt certificate for $NOTES_DOMAIN"
    obtain_letsencrypt_cert "$NOTES_DOMAIN"
    say "Requesting Let's Encrypt certificate for $FILES_DOMAIN"
    obtain_letsencrypt_cert "$FILES_DOMAIN"
    NOTES_SSL_CERT="/etc/letsencrypt/live/$NOTES_DOMAIN/fullchain.pem"
    NOTES_SSL_KEY="/etc/letsencrypt/live/$NOTES_DOMAIN/privkey.pem"
    FILES_SSL_CERT="/etc/letsencrypt/live/$FILES_DOMAIN/fullchain.pem"
    FILES_SSL_KEY="/etc/letsencrypt/live/$FILES_DOMAIN/privkey.pem"

    install -d -m 0755 /etc/letsencrypt/renewal-hooks/deploy
    cat > /etc/letsencrypt/renewal-hooks/deploy/reload-nginx-standardnotes.sh <<'EOF'
#!/usr/bin/env bash
systemctl reload nginx >/dev/null 2>&1 || true
EOF
    chmod +x /etc/letsencrypt/renewal-hooks/deploy/reload-nginx-standardnotes.sh
  else
    local pair
    pair="$(create_self_signed_cert "$NOTES_DOMAIN")"
    NOTES_SSL_CERT="${pair%%|*}"; NOTES_SSL_KEY="${pair##*|}"
    pair="$(create_self_signed_cert "$FILES_DOMAIN")"
    FILES_SSL_CERT="${pair%%|*}"; FILES_SSL_KEY="${pair##*|}"
  fi

  render_standardnotes_template "$INSTALL_DIR/nginx/standardnotes-https.conf.template" "$NGINX_SITE_AVAILABLE"
  nginx -t
  systemctl reload nginx
  ok "Nginx HTTPS reverse proxy configured"
}

configure_fail2ban() {
  step "Configuring Fail2ban for Nginx"
  cp "$INSTALL_DIR/fail2ban/filter.d/standardnotes-nginx-4xx.conf" /etc/fail2ban/filter.d/standardnotes-nginx-4xx.conf
  cp "$INSTALL_DIR/fail2ban/filter.d/standardnotes-nginx-dashboard-auth.conf" /etc/fail2ban/filter.d/standardnotes-nginx-dashboard-auth.conf
  cp "$INSTALL_DIR/fail2ban/jail.d/standardnotes-nginx.local" /etc/fail2ban/jail.d/standardnotes-nginx.local
  systemctl enable --now fail2ban
  fail2ban-client reload || systemctl restart fail2ban
  ok "Fail2ban configured"
}

install_snctl_cli() {
  if [[ "$INSTALL_SNCTL" != "yes" ]]; then
    warn "snctl CLI was not installed globally. You can still run: $INSTALL_DIR/scripts/snctl"
    return
  fi

  step "Installing snctl management CLI"
  ln -sf "$INSTALL_DIR/scripts/snctl" /usr/local/bin/snctl
  chmod +x "$INSTALL_DIR/scripts/snctl"
  ok "Installed /usr/local/bin/snctl"
}

install_backup_timer() {
  step "Installing backup systemd timer"
  render_install_template "$INSTALL_DIR/systemd/standardnotes-backup.service.template" /etc/systemd/system/standardnotes-backup.service
  render_install_template "$INSTALL_DIR/systemd/standardnotes-backup.timer.template" /etc/systemd/system/standardnotes-backup.timer
  systemctl daemon-reload
  systemctl enable --now standardnotes-backup.timer
  systemctl list-timers standardnotes-backup.timer --no-pager || true
  ok "Backup timer enabled"
}

wait_for_http_any_status() {
  local url="$1" label="$2" code
  for _ in {1..60}; do
    code="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 3 "$url" 2>/dev/null || printf '000')"
    if [[ "$code" != "000" ]]; then
      ok "$label is reachable at $url (HTTP $code)"
      return 0
    fi
    sleep 3
  done
  warn "$label did not become reachable at $url within the wait period. Check docker compose logs."
  return 1
}

start_standard_notes() {
  step "Starting Standard Notes Docker Compose stack"
  say "Running official flow: docker compose pull && docker compose up -d"
  (cd "$INSTALL_DIR" && docker compose pull && docker compose up -d)
  wait_for_http_any_status "http://127.0.0.1:3000" "Standard Notes API" || true
  wait_for_http_any_status "http://127.0.0.1:3125" "Standard Notes files server" || true
  ok "Docker Compose stack started"
}

run_first_account_flow_if_requested() {
  if [[ "$RUN_FIRST_ACCOUNT_FLOW" != "yes" ]]; then
    return
  fi

  step "Starting guided first-account PRO_PLAN flow"
  "$INSTALL_DIR/scripts/snctl" first-account "$FIRST_ACCOUNT_EMAIL"
}

run_initial_backup_if_requested() {
  if [[ "$RUN_INITIAL_BACKUP" != "yes" ]]; then
    return
  fi
  step "Running initial backup"
  if SN_PROJECT_DIR="$INSTALL_DIR" SN_BACKUP_RETENTION_DAYS="$BACKUP_RETENTION_DAYS" "$INSTALL_DIR/scripts/backup.sh"; then
    ok "Initial backup completed"
  else
    warn "Initial backup failed. The services may still be initializing; retry with: sudo $INSTALL_DIR/scripts/backup.sh"
  fi
}

run_tests() {
  step "Running health checks"
  if SN_PROJECT_DIR="$INSTALL_DIR" "$INSTALL_DIR/scripts/healthcheck.sh"; then
    ok "Health check passed"
  else
    warn "Health check reported warnings/failures. Review the output above and logs."
  fi
}

print_summary() {
  cat <<SUMMARY

${BOLD}Installation complete${RESET}

URLs:
  Notes/API:   https://$NOTES_DOMAIN
  Files:       https://$FILES_DOMAIN
  Dashboard:   https://$NOTES_DOMAIN/dashboard/

Open in your host/cloud firewall:
  - TCP 80  (HTTP redirect and Let's Encrypt renewal)
  - TCP 443 (HTTPS)
  - TCP $SSH_PORT (SSH)

Keep closed publicly:
  - TCP 3000 (Standard Notes API, bound to 127.0.0.1)
  - TCP 3125 (Standard Notes files server, bound to 127.0.0.1)
  - TCP 8090 (dashboard app, bound to 127.0.0.1)

Useful commands:
  cd $INSTALL_DIR
  # If you did not install the global CLI, use: $INSTALL_DIR/scripts/snctl COMMAND
  docker compose ps
  docker compose logs -f server
  snctl health
  snctl test
  snctl backup
  snctl first-account EMAIL@ADDR
  snctl grant-pro EMAIL@ADDR --wait
  snctl update

Verification commands:
  curl -I https://$NOTES_DOMAIN
  curl -I https://$FILES_DOMAIN
  curl -sS -o /dev/null -w 'API HTTP %{http_code}\n' http://127.0.0.1:3000
  curl -sS -o /dev/null -w 'Files HTTP %{http_code}\n' http://127.0.0.1:3125

Standard Notes client setup:
  1. Install/open the Standard Notes desktop or mobile app.
  2. Open Account menu -> Advanced options -> Sync Server -> Custom.
  3. Enter: https://$NOTES_DOMAIN
  4. Register your first account on this custom server.
  5. Create a note and confirm it syncs. File uploads use PUBLIC_FILES_SERVER_URL=https://$FILES_DOMAIN.
  6. To automate first-account setup from the server, run:
     snctl first-account EMAIL@ADDR
     This opens registration, waits for the account, grants server-side PRO_PLAN,
     and asks whether to lock registration.
  7. After your first account exists, consider locking registration:
     - run snctl lock-registration, or
     - rerun sudo $INSTALL_DIR/install.sh and answer Yes to disabling registration, or
     - set AUTH_SERVER_DISABLE_USER_REGISTRATION=true in $INSTALL_DIR/.env and run docker compose up -d.

Backups:
  Timer:     standardnotes-backup.timer ($BACKUP_ON_CALENDAR)
  Location:  $INSTALL_DIR/backups
  Restore:   sudo $INSTALL_DIR/scripts/restore.sh /path/to/standardnotes-backup-*.tar.gz
SUMMARY

  if [[ -n "$GENERATED_DASHBOARD_PASSWORD" ]]; then
    cat <<PASSWORD

Generated dashboard credentials:
  Username: $DASHBOARD_USER
  Password: $GENERATED_DASHBOARD_PASSWORD

Store this password now. It is not saved in plaintext.
PASSWORD
  fi

  if [[ "$USE_LETSENCRYPT" != "yes" ]]; then
    warn "Self-signed certificates are installed. Replace them with trusted certificates before using Standard Notes clients in production."
  elif [[ "$CERTBOT_STAGING" == "yes" ]]; then
    warn "Let's Encrypt staging certificates are installed and are not trusted by clients. Rerun install.sh with staging disabled for production."
  fi
}

main() {
  require_root "$@"
  check_ubuntu
  ask_config
  install_base_packages
  install_docker
  copy_project_files
  write_install_config
  write_env_file
  configure_auto_updates
  configure_logrotate
  install_dashboard
  install_snctl_cli
  configure_firewall
  configure_nginx
  configure_fail2ban
  install_backup_timer
  start_standard_notes
  run_first_account_flow_if_requested
  run_initial_backup_if_requested
  run_tests
  print_summary
}

main "$@"
