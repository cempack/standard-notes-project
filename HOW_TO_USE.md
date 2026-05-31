# How to use this Standard Notes self-hosting repo

This guide is the short, practical version for getting the repo running on a fresh Ubuntu server.

GitHub repo:

```text
https://github.com/cempack/standard-notes-project
```

## 1. Prepare DNS

Create two DNS records pointing at your Ubuntu server's public IP address:

```text
notes.yourdomain.com  -> YOUR_SERVER_PUBLIC_IP
files.yourdomain.com  -> YOUR_SERVER_PUBLIC_IP
```

Example:

```text
notes.example.com
files.example.com
```

Use two different hostnames. The notes domain is for the Standard Notes API. The files domain is for Standard Notes file uploads.

## 2. Open the right firewall ports

In your cloud provider firewall/security group, allow inbound:

```text
80/tcp     HTTP for Let's Encrypt certificate validation and redirects
443/tcp    HTTPS for Standard Notes and the dashboard
22/tcp     SSH, or your custom SSH port
```

Do **not** publicly open these ports:

```text
3000       Standard Notes API, private behind Nginx
3125       Standard Notes files server, private behind Nginx
8090       dashboard app, private behind Nginx
3306       MySQL
6379       Redis
4566       LocalStack
```

The installer binds `3000`, `3125`, and `8090` to `127.0.0.1` only.

## 3. SSH into the server

```bash
ssh root@YOUR_SERVER_PUBLIC_IP
```

or, if you use a sudo user:

```bash
ssh youruser@YOUR_SERVER_PUBLIC_IP
```

## 4. Clone the repo

```bash
sudo apt update
sudo apt install -y git

git clone https://github.com/cempack/standard-notes-project.git
cd standard-notes-project
```

## 5. Run the installer

```bash
chmod +x install.sh
sudo ./install.sh
```

The installer is interactive. It will explain each step and ask for values.

Recommended answers for a first install:

```text
Install directory: /opt/standardnotes
Notes/API domain: notes.yourdomain.com
Files domain: files.yourdomain.com
Let's Encrypt certificates: yes
Let's Encrypt staging certificates: no
Enable unattended security updates: yes
Configure UFW firewall: yes
Disable new user registration now: no
Install snctl management CLI: yes
After services start, wait for your first account and grant server-side PRO_PLAN automatically: yes or no
Run initial backup: yes
```

Important: answer **No** to disabling registration during the first install unless you already created the account. You need registration open once so you can create your first Standard Notes account.

If you answer **Yes** to the automatic first-account flow, the installer will wait after services start. Open Standard Notes, register the email you entered, and the CLI will grant server-side `PRO_PLAN` automatically.

The installer will:

- install Docker, Nginx, Certbot, Fail2ban, UFW, Go, and backup tools
- generate secure Standard Notes secrets
- write `/opt/standardnotes/.env`
- set `PUBLIC_FILES_SERVER_URL=https://files.yourdomain.com`
- configure HTTPS Nginx reverse proxy
- start the Standard Notes Docker Compose stack
- install the dashboard
- install the `snctl` management CLI
- optionally wait for your first account, grant server-side `PRO_PLAN`, and lock registration
- configure scheduled backups
- print verification commands and next steps

## 6. Verify the install

Run:

```bash
curl -I https://notes.yourdomain.com
curl -I https://files.yourdomain.com
```

Check Docker containers:

```bash
cd /opt/standardnotes
docker compose ps
```

Run the health checker:

```bash
sudo /opt/standardnotes/scripts/healthcheck.sh
```

Run the guided test script:

```bash
sudo /opt/standardnotes/scripts/test.sh
```

## 7. Use the management CLI

If you chose to install it, `snctl` is available globally:

```bash
snctl help
```

Common commands:

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

The easiest first-account flow is:

```bash
snctl first-account you@example.com
```

That command:

1. opens registration,
2. prints your sync server URL,
3. waits for you to register `you@example.com` in the Standard Notes app,
4. grants server-side `PRO_USER` / `PRO_PLAN`, and
5. asks whether to lock registration afterward.

## 8. Open the dashboard

Go to:

```text
https://notes.yourdomain.com/dashboard/
```

Use the dashboard username and password you entered during installation.

The dashboard shows:

- Standard Notes API health
- files server health
- public HTTPS checks
- latest backup
- recent logs

## 9. Configure the Standard Notes app

Use the Standard Notes desktop or mobile app.

In the app:

```text
Account menu -> Advanced options -> Sync Server -> Custom
```

Set the custom sync server to:

```text
https://notes.yourdomain.com
```

Then register your first account.

After registering:

1. Create a note.
2. Confirm it syncs.
3. Test file uploads if you use Standard Notes file features.

## 10. Lock registration after your first account

After your first account exists, disable new public account registration.

Run:

```bash
snctl lock-registration
```

Or rerun the installer:

```bash
cd /opt/standardnotes
sudo ./install.sh
```

When prompted, answer **Yes** to disabling new user registration.

## 11. Grant server-side premium subscription features

Standard Notes documents a self-hosted database change for granting your account a server-side `PRO_PLAN` subscription. This repo includes a helper script for that.

After your account exists, use the automated CLI command:

```bash
snctl grant-pro EMAIL@ADDR --wait
```

Or run the lower-level helper directly:

```bash
sudo /opt/standardnotes/scripts/grant-pro-subscription.sh --wait EMAIL@ADDR
```

Example:

```bash
snctl grant-pro you@example.com --wait
```

This grants:

- `PRO_USER` role
- `PRO_PLAN` subscription with a far-future expiry

Important limitation:

- This unlocks server-side premium features on your self-hosted server.
- It does **not** unlock client-side premium features such as Super notes or Nested tags in official clients.
- For full client-side premium features, Standard Notes requires an offline plan.

The helper validates the email, checks the user exists, checks the `PRO_USER` role exists, and is safe to rerun for the same user.

Official manual equivalent from your working directory:

```bash
docker compose exec db sh -c "MYSQL_PWD=\$MYSQL_ROOT_PASSWORD mysql \$MYSQL_DATABASE -e \
  'INSERT INTO user_roles (role_uuid , user_uuid) VALUES ((SELECT uuid FROM roles WHERE name=\"PRO_USER\" ORDER BY version DESC limit 1) ,(SELECT uuid FROM users WHERE email=\"EMAIL@ADDR\")) ON DUPLICATE KEY UPDATE role_uuid = VALUES(role_uuid);' \
"

docker compose exec db sh -c "MYSQL_PWD=\$MYSQL_ROOT_PASSWORD mysql \$MYSQL_DATABASE -e \
  'INSERT INTO user_subscriptions SET uuid=UUID(), plan_name=\"PRO_PLAN\", ends_at=8640000000000000, created_at=0, updated_at=0, user_uuid=(SELECT uuid FROM users WHERE email=\"EMAIL@ADDR\"), subscription_id=1, subscription_type=\"regular\";' \
"
```

## 12. Backups

Backups are scheduled automatically with systemd.

Check the backup timer:

```bash
systemctl list-timers standardnotes-backup.timer --no-pager
```

Run a manual backup:

```bash
sudo /opt/standardnotes/scripts/backup.sh
```

Backup files are stored in:

```text
/opt/standardnotes/backups/
```

Backups contain sensitive data, including the database and `.env` secrets. Copy them off-server securely.

## 13. Restore from backup

Copy your backup archive and `.sha256` file to the server, then run:

```bash
sudo /opt/standardnotes/scripts/restore.sh /path/to/standardnotes-backup-YYYYmmddTHHMMSSZ.tar.gz
```

You will be asked to type:

```text
RESTORE
```

After restore, run:

```bash
sudo /opt/standardnotes/scripts/healthcheck.sh
```

## 14. Update Standard Notes later

Use the update helper:

```bash
sudo /opt/standardnotes/scripts/update.sh
```

It will:

1. run a backup
2. pull new Docker images
3. restart containers
4. run a health check

Manual equivalent:

```bash
sudo /opt/standardnotes/scripts/backup.sh
cd /opt/standardnotes
docker compose pull
docker compose up -d
sudo /opt/standardnotes/scripts/healthcheck.sh
```

## 15. Common commands

View container status:

```bash
cd /opt/standardnotes
docker compose ps
```

View Standard Notes logs:

```bash
cd /opt/standardnotes
docker compose logs -f server
```

View Nginx errors:

```bash
sudo tail -f /var/log/nginx/standardnotes-error.log
sudo tail -f /var/log/nginx/standardnotes-files-error.log
```

Restart Standard Notes:

```bash
cd /opt/standardnotes
sudo docker compose up -d
```

Restart Nginx:

```bash
sudo nginx -t
sudo systemctl reload nginx
```

Check Fail2ban:

```bash
sudo fail2ban-client status
```

Check dashboard service:

```bash
sudo systemctl status standardnotes-dashboard
sudo journalctl -u standardnotes-dashboard -n 100 --no-pager
```

## 16. Troubleshooting quick checks

If HTTPS does not work:

```bash
curl -I http://notes.yourdomain.com
curl -I https://notes.yourdomain.com
sudo nginx -t
sudo systemctl status nginx
```

If Nginx returns `502`:

```bash
cd /opt/standardnotes
docker compose ps
docker compose logs --tail=200 server
curl -sS -o /dev/null -w '%{http_code}\n' http://127.0.0.1:3000
curl -sS -o /dev/null -w '%{http_code}\n' http://127.0.0.1:3125
```

If the Standard Notes client cannot sync:

- Confirm the sync server is exactly `https://notes.yourdomain.com`.
- Do not include `/dashboard` or any extra path.
- Confirm certificates are trusted, not staging/self-signed.
- Confirm containers are running with `docker compose ps`.
- Confirm `.env` has the correct files URL:

```bash
grep '^PUBLIC_FILES_SERVER_URL=' /opt/standardnotes/.env
```

## 17. Start-to-finish copy/paste example

Replace the domains with your real domains during the installer prompts.

```bash
sudo apt update
sudo apt install -y git

git clone https://github.com/cempack/standard-notes-project.git
cd standard-notes-project
chmod +x install.sh
sudo ./install.sh

sudo /opt/standardnotes/scripts/healthcheck.sh
```

Then configure your Standard Notes app with:

```text
https://notes.yourdomain.com
```
