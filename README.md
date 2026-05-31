# Standard Notes self-hosting project

A production-minded, one-server Standard Notes self-hosting repo for Ubuntu. It follows the official Docker flow:

1. Generate `.env` with required secrets and `PUBLIC_FILES_SERVER_URL`.
2. Use the Standard Notes Docker Compose topology: `server`, `localstack`, `db`, and `cache`.
3. Include `localstack_bootstrap.sh`.
4. Run `docker compose pull && docker compose up -d`.

The installer adds a secure Nginx HTTPS reverse proxy, Fail2ban, UFW rules, unattended Ubuntu security updates, automated backups, restore tooling, health checks, and a small password-protected dashboard.

## Architecture

```text
Internet
  |
  | TCP 443 HTTPS
  v
Nginx
  |-- https://notes.example.com  -> 127.0.0.1:3000  Standard Notes API
  |-- https://files.example.com  -> 127.0.0.1:3125  Standard Notes files server
  |-- https://notes.example.com/dashboard/ -> 127.0.0.1:8090 dashboard

Docker Compose network
  |-- standardnotes/server
  |-- mysql:8
  |-- redis:6.0-alpine
  |-- localstack/localstack:3.0
```

Publicly open only:

- `80/tcp` for Let's Encrypt HTTP validation and HTTP-to-HTTPS redirect.
- `443/tcp` for HTTPS.
- Your SSH port.

Do **not** expose `3000`, `3125`, `8090`, MySQL, Redis, or LocalStack publicly.

## Repository tree

```text
standard-notes-project/
  install.sh
  README.md
  docker-compose.yml
  .env.example
  .gitignore
  localstack_bootstrap.sh
  backups/
    .gitkeep
  configs/
    logrotate/
      standardnotes
    unattended-upgrades/
      52standardnotes-unattended-upgrades
  dashboard/
    go.mod
    main.go
  fail2ban/
    filter.d/
      standardnotes-nginx-4xx.conf
      standardnotes-nginx-dashboard-auth.conf
    jail.d/
      standardnotes-nginx.local
  nginx/
    standardnotes-http.conf.template
    standardnotes-https.conf.template
  scripts/
    backup.sh
    grant-pro-subscription.sh
    healthcheck.sh
    restore.sh
    snctl
    test.sh
    update.sh
  systemd/
    standardnotes-backup.service.template
    standardnotes-backup.timer.template
    standardnotes-dashboard.service.template
```

## Requirements

- Fresh Ubuntu server, recommended Ubuntu 22.04 LTS or 24.04 LTS.
- Root or sudo access.
- DNS records already pointing to the server:
  - `notes.example.com` -> server public IP
  - `files.example.com` -> server public IP
- Cloud firewall/security group allows:
  - `80/tcp`
  - `443/tcp`
  - your SSH port
- At least 2 GB RAM is recommended by Standard Notes for the Docker setup.

## Installation

Upload or unzip this repository on the server, then run:

```bash
cd standard-notes-project
chmod +x install.sh
sudo ./install.sh
```

The installer asks for:

- Install directory, default `/opt/standardnotes`.
- Notes/API domain, for example `notes.example.com`.
- Files domain, for example `files.example.com`.
- Email for Let's Encrypt.
- Dashboard username/password.
- SSH port to keep open in UFW.
- Whether to use Let's Encrypt or temporary self-signed certificates.
- Whether to enable unattended Ubuntu security updates.
- Whether to enable UFW firewall rules.
- Whether to disable new user registration immediately (choose no until your first account exists).
- Whether to install the `snctl` management CLI.
- Whether to run a guided first-account flow after services start. This opens registration, waits for your account, grants server-side `PRO_PLAN`, and asks whether to lock registration.
- Whether to add your sudo user to the Docker group. This is optional and root-equivalent.
- Backup retention and schedule.
- Whether to run an initial backup.

The script is safe to rerun. It preserves existing Standard Notes secrets from `.env`, backs up an existing `.env` before rewriting managed values, and keeps the dashboard password if you leave it blank and do not change the dashboard username.

## What the installer does

- Installs packages:
  - Docker Engine and Docker Compose plugin
  - Nginx
  - Certbot
  - Fail2ban
  - UFW
  - unattended-upgrades
  - Go compiler for the dashboard
  - backup/test dependencies
- Copies this project to `/opt/standardnotes` or your selected install directory.
- Generates `.env` with:
  - `DB_PASSWORD`
  - `AUTH_JWT_SECRET`
  - `AUTH_SERVER_ENCRYPTION_SERVER_KEY`
  - `VALET_TOKEN_SECRET`
  - `AUTH_SERVER_DISABLE_USER_REGISTRATION=false` by default for first-account registration
  - `PUBLIC_FILES_SERVER_URL=https://files.example.com`
- Runs:

```bash
docker compose pull && docker compose up -d
```

- Configures Nginx:
  - `https://notes.example.com` -> `127.0.0.1:3000`
  - `https://files.example.com` -> `127.0.0.1:3125`
  - `https://notes.example.com/dashboard/` -> `127.0.0.1:8090`
- Installs Fail2ban jails for Nginx auth/bot/4xx abuse.
- Enables automatic Ubuntu security updates if selected.
- Enables a `standardnotes-backup.timer` systemd backup schedule.
- Builds and runs the Go dashboard as a locked-down `sn-dashboard` system user.
- Installs `snctl` to `/usr/local/bin/snctl` when selected.

## Management CLI: `snctl`

When selected during installation, the installer creates:

```text
/usr/local/bin/snctl -> /opt/standardnotes/scripts/snctl
```

Useful commands:

```bash
snctl status
snctl health
snctl logs server
snctl backup
snctl update
snctl registration-status
snctl lock-registration
snctl unlock-registration
snctl first-account EMAIL@ADDR
snctl grant-pro EMAIL@ADDR --wait
```

`snctl first-account EMAIL@ADDR` is the automated first-account flow. It:

1. opens registration,
2. prints the Sync Server URL,
3. waits up to 30 minutes for that email to register,
4. grants server-side `PRO_USER`/`PRO_PLAN`, and
5. asks whether to lock registration afterward.

## Standard Notes client setup

In the Standard Notes desktop or mobile app:

1. Open the account menu.
2. Choose **Advanced options**.
3. Under **Sync Server**, choose **Custom**.
4. Enter your notes URL, for example:

```text
https://notes.example.com
```

5. Register your first account on that custom server.
6. Create a note and confirm it syncs.
7. After your first account exists, run the automated CLI flow if you did not run it during install:

```bash
snctl first-account you@example.com
```

This grants server-side `PRO_PLAN` and asks whether to lock registration.

To lock registration manually:

```bash
snctl lock-registration
```

You can also rerun `sudo /opt/standardnotes/install.sh` and answer yes to disabling registration.

File uploads are served through the files domain set in `.env`:

```text
PUBLIC_FILES_SERVER_URL=https://files.example.com
```

The official hosted web app at `app.standardnotes.com` is not used with a custom sync server. Use the desktop/mobile apps or self-host the Standard Notes web app separately.

## Dashboard

The dashboard is available at:

```text
https://notes.example.com/dashboard/
```

It is protected twice:

1. Nginx Basic Auth using `/etc/nginx/standardnotes-dashboard.htpasswd`.
2. The dashboard app's own Basic Auth validation using salted SHA-256 values in `/etc/standardnotes-dashboard.env`.

It shows:

- Local API status.
- Local files server status.
- Public HTTPS status for notes and files domains.
- Latest backup metadata.
- Recent Nginx and Standard Notes log snippets when readable.

Service commands:

```bash
sudo systemctl status standardnotes-dashboard
sudo systemctl restart standardnotes-dashboard
sudo journalctl -u standardnotes-dashboard -n 100 --no-pager
```

## Health checks and tests

Run the built-in health checker:

```bash
sudo /opt/standardnotes/scripts/healthcheck.sh
```

Run the guided test script:

```bash
sudo /opt/standardnotes/scripts/test.sh
```

Manual checks:

```bash
curl -I https://notes.example.com
curl -I https://files.example.com
curl -sS -o /dev/null -w 'API HTTP %{http_code}\n' http://127.0.0.1:3000
curl -sS -o /dev/null -w 'Files HTTP %{http_code}\n' http://127.0.0.1:3125
cd /opt/standardnotes && docker compose ps
cd /opt/standardnotes && docker compose logs -f server
```

A `404` or `401` from a root API URL can still mean the service is reachable; the important first signal is that the connection succeeds and does not return a `5xx` or timeout.

## Server-side premium subscription helper

Standard Notes documents a self-hosted database change for granting an account a server-side `PRO_PLAN` subscription. This repo includes a safer helper wrapper.

After your account exists, run either:

```bash
snctl grant-pro EMAIL@ADDR --wait
```

or:

```bash
sudo /opt/standardnotes/scripts/grant-pro-subscription.sh --wait EMAIL@ADDR
```

Example:

```bash
snctl grant-pro you@example.com --wait
```

This grants the `PRO_USER` role and `PRO_PLAN` subscription with a far-future expiry.

Important: this unlocks server-side premium features only. It does **not** unlock client-side premium features such as Super notes or Nested tags in official clients. For full client-side premium features, use a Standard Notes offline plan.

Manual equivalent from the official docs:

```bash
docker compose exec db sh -c "MYSQL_PWD=\$MYSQL_ROOT_PASSWORD mysql \$MYSQL_DATABASE -e \
  'INSERT INTO user_roles (role_uuid , user_uuid) VALUES ((SELECT uuid FROM roles WHERE name=\"PRO_USER\" ORDER BY version DESC limit 1) ,(SELECT uuid FROM users WHERE email=\"EMAIL@ADDR\")) ON DUPLICATE KEY UPDATE role_uuid = VALUES(role_uuid);' \
"

docker compose exec db sh -c "MYSQL_PWD=\$MYSQL_ROOT_PASSWORD mysql \$MYSQL_DATABASE -e \
  'INSERT INTO user_subscriptions SET uuid=UUID(), plan_name=\"PRO_PLAN\", ends_at=8640000000000000, created_at=0, updated_at=0, user_uuid=(SELECT uuid FROM users WHERE email=\"EMAIL@ADDR\"), subscription_id=1, subscription_type=\"regular\";' \
"
```

## Backups

Backups are managed by:

```text
standardnotes-backup.timer
standardnotes-backup.service
```

Check the timer:

```bash
systemctl list-timers standardnotes-backup.timer --no-pager
```

Run a manual backup:

```bash
sudo /opt/standardnotes/scripts/backup.sh
```

Backups are written to:

```text
/opt/standardnotes/backups/standardnotes-backup-YYYYmmddTHHMMSSZ.tar.gz
/opt/standardnotes/backups/standardnotes-backup-YYYYmmddTHHMMSSZ.tar.gz.sha256
/opt/standardnotes/backups/LATEST.json
```

Each backup includes:

- MySQL dump.
- Upload data.
- Redis data snapshot/cache data.
- `.env`, `docker-compose.yml`, `localstack_bootstrap.sh`, and `.install-config` when present.

Backups contain secrets. Store off-server copies securely and restrict access.

## Restore

Copy the backup archive and its `.sha256` sidecar to the server, then run:

```bash
sudo /opt/standardnotes/scripts/restore.sh /path/to/standardnotes-backup-YYYYmmddTHHMMSSZ.tar.gz
```

You must type `RESTORE` to confirm. The restore script:

1. Verifies the `.sha256` sidecar when present.
2. Saves a pre-restore copy of current config to `/opt/standardnotes/pre-restore-*`.
3. Stops the current Compose stack.
4. Restores config, uploads, and Redis data.
5. Starts MySQL/Redis/LocalStack.
6. Moves the current `data/mysql` directory aside to `data/mysql.pre-restore-*` so the restored `.env` database password can initialize a clean MySQL data directory.
7. Drops and recreates the Standard Notes database in the clean MySQL instance.
8. Imports the SQL dump.
9. Starts the full stack.

After restore:

```bash
sudo /opt/standardnotes/scripts/healthcheck.sh
```

## Updates

Use the update helper:

```bash
sudo /opt/standardnotes/scripts/update.sh
```

It runs a backup first, then:

```bash
cd /opt/standardnotes
docker compose pull
docker compose up -d
```

You can also update manually:

```bash
sudo /opt/standardnotes/scripts/backup.sh
cd /opt/standardnotes
docker compose pull
docker compose up -d
sudo /opt/standardnotes/scripts/healthcheck.sh
```

For major Standard Notes server changes, compare this repo's `.env.example`, `docker-compose.yml`, and `localstack_bootstrap.sh` with the upstream Standard Notes examples before updating.

## Changing domains later

1. Update DNS for the new domains.
2. Rerun the installer:

```bash
cd /opt/standardnotes
sudo ./install.sh
```

3. Enter the new notes/files domains.
4. Let the installer update `.env`, Nginx, certificates, dashboard config, and health checks.
5. Confirm `.env` contains the new files URL:

```bash
grep '^PUBLIC_FILES_SERVER_URL=' /opt/standardnotes/.env
```

## Changing the dashboard password

Rerun the installer and enter a new dashboard password when prompted:

```bash
cd /opt/standardnotes
sudo ./install.sh
```

Or manually update Nginx Basic Auth and the dashboard app hash. Rerunning the installer is safer because it keeps both layers in sync.

## Changing Standard Notes secrets or database password

Do not rotate `DB_PASSWORD` by editing `.env` alone on an existing database. MySQL users inside the existing data directory will still have the old password.

Safer approaches:

- For a new empty install: stop containers, remove `data/mysql`, update `.env`, and start again.
- For an existing install: take a backup, update the MySQL user's password inside MySQL, update `.env`, then restart. Test thoroughly.

The installer intentionally preserves existing `.env` secrets on rerun.

## Changing host ports

The project defaults are intentionally private:

```yaml
127.0.0.1:3000:3000
127.0.0.1:3125:3104
```

If you must change them:

1. Edit `/opt/standardnotes/docker-compose.yml` port bindings.
2. Edit Nginx upstreams in `/etc/nginx/sites-available/standardnotes.conf` or update the template and rerun the installer.
3. Restart:

```bash
cd /opt/standardnotes
docker compose up -d
sudo nginx -t && sudo systemctl reload nginx
```

Keep the services bound to `127.0.0.1` unless you have a very specific reason not to.

## Logs

Useful logs:

```bash
cd /opt/standardnotes
docker compose logs -f server
docker compose logs -f db
docker compose logs -f localstack
sudo tail -f /var/log/nginx/standardnotes-error.log
sudo tail -f /var/log/nginx/standardnotes-files-error.log
sudo journalctl -u standardnotes-dashboard -f
sudo journalctl -u standardnotes-backup -n 100 --no-pager
```

Standard Notes container file logs are mounted at:

```text
/opt/standardnotes/logs/
```

## Troubleshooting

### Certbot fails

Check all of these:

- DNS A/AAAA records point to this server.
- Cloud firewall allows `80/tcp` inbound.
- UFW allows `80/tcp`.
- No other service is using port 80.
- `http://notes.example.com/.well-known/acme-challenge/test` reaches this server.

Then rerun:

```bash
cd /opt/standardnotes
sudo ./install.sh
```

For testing without rate limits, choose Let's Encrypt staging certificates. Staging certificates are not trusted by clients.

### Nginx returns 502

The Docker service behind Nginx is not reachable yet.

```bash
cd /opt/standardnotes
docker compose ps
docker compose logs --tail=200 server
curl -sS -o /dev/null -w '%{http_code}\n' http://127.0.0.1:3000
curl -sS -o /dev/null -w '%{http_code}\n' http://127.0.0.1:3125
```

Wait a few minutes on first boot; MySQL initialization can take time.

### Docker Compose fails with a DB password or MySQL auth error

If this is a rerun on an existing install, do not regenerate `DB_PASSWORD`. The installer preserves it automatically. If you manually changed it, restore the old value from `.env.bak.*` or rotate the MySQL password properly inside MySQL.

### Dashboard login loops

The dashboard uses both Nginx Basic Auth and app Basic Auth with the same credentials. Rerun the installer and set a new dashboard password to resync both layers:

```bash
cd /opt/standardnotes
sudo ./install.sh
```

### Fail2ban banned my IP

Check jails:

```bash
sudo fail2ban-client status
sudo fail2ban-client status standardnotes-nginx-dashboard-auth
sudo fail2ban-client unban YOUR_IP_ADDRESS
```

### Client cannot sync

Check:

- The client Sync Server is exactly `https://notes.example.com` with no trailing path.
- Your certificate is trusted, not self-signed or Let's Encrypt staging.
- `curl -I https://notes.example.com` succeeds.
- `docker compose ps` shows the server container running.
- `PUBLIC_FILES_SERVER_URL=https://files.example.com` is present in `.env`.

## Security notes

- Secrets are generated with `openssl rand` and stored in `.env` mode `0600`.
- The installer does not add users to the Docker group unless you opt in. Docker group membership is root-equivalent.
- Docker service ports are bound to `127.0.0.1` only.
- Nginx is the only public HTTP entry point.
- HTTPS redirects and HSTS are enabled.
- Dashboard is Basic Auth protected and served only through HTTPS.
- Fail2ban protects SSH and Nginx auth/bot abuse.
- UFW opens only SSH, 80, and 443 when enabled.
- Ubuntu unattended security updates are enabled when selected.
- Docker containers use `restart: unless-stopped`.
- Backups are mode `0600` and include sensitive data.

## Optional future improvements

- Off-site encrypted backup sync to S3-compatible storage or restic/borg.
- Separate dashboard subdomain if you prefer not to host it under `/dashboard/`.
- Monitoring integration with Prometheus/Grafana or uptime checks.
- Self-hosting the Standard Notes web app as a separate service.
- More granular Fail2ban tuning after observing real traffic patterns.
