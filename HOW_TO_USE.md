<div align="center">

# 📝 Standard Notes — Self-Hosting Guide

**Your private, encrypted notes server — up and running in under 30 minutes.**

[![GitHub](https://img.shields.io/badge/GitHub-cempack%2Fstandard--notes--project-blue?style=flat-square&logo=github)](https://github.com/cempack/standard-notes-project)

</div>

---

> **⏱ Estimated time:** 15–30 minutes (depending on DNS propagation)
>
> **🖥 Target OS:** Ubuntu 22.04+ (fresh server recommended)

### Prerequisites Checklist

Before you begin, make sure you have:

- [ ] A fresh Ubuntu server with a public IP address
- [ ] Root or sudo access via SSH
- [ ] Two DNS hostnames ready (e.g. `notes.yourdomain.com` & `files.yourdomain.com`)
- [ ] Ports 80, 443, and 22 open in your cloud provider's firewall
- [ ] The Standard Notes desktop or mobile app installed on your device

---

## 📡 Step 1 — Prepare DNS

Create **two** A records pointing at your server's public IP. Each domain serves a different purpose:

| Record | Hostname | Points To | Purpose |
|:------:|:---------|:----------|:--------|
| `A` | `notes.yourdomain.com` | `YOUR_SERVER_PUBLIC_IP` | Standard Notes API & sync |
| `A` | `files.yourdomain.com` | `YOUR_SERVER_PUBLIC_IP` | Encrypted file uploads |

> [!IMPORTANT]
> You **must** use two separate hostnames. The notes domain handles the API; the files domain handles file uploads. They cannot be the same.

> [!TIP]
> DNS propagation can take up to 30 minutes. Set your records first, then continue with the remaining steps while they propagate.

---

## 🔒 Step 2 — Open Firewall Ports

Configure your cloud provider's firewall or security group. Only three ports should be publicly accessible:

### ✅ Ports to Open (Public)

| Port | Protocol | Purpose | Status |
|:----:|:--------:|:--------|:------:|
| `80` | TCP | Let's Encrypt validation & HTTP→HTTPS redirect | 🟢 Open |
| `443` | TCP | HTTPS for Standard Notes & dashboard | 🟢 Open |
| `22` | TCP | SSH access (or your custom SSH port) | 🟢 Open |

### 🚫 Ports to Keep Closed (Internal Only)

| Port | Service | Why It's Private |
|:----:|:--------|:-----------------|
| `3000` | Standard Notes API | Behind Nginx reverse proxy |
| `3125` | Files server | Behind Nginx reverse proxy |
| `8090` | Dashboard app | Behind Nginx reverse proxy |
| `3306` | MySQL | Database — no public access |
| `6379` | Redis | Cache — no public access |
| `4566` | LocalStack | S3-compatible storage — no public access |

> [!NOTE]
> The installer automatically binds ports `3000`, `3125`, and `8090` to `127.0.0.1` only, so they are never exposed externally even without firewall rules.

---

## 🔑 Step 3 — SSH into the Server

Connect as root:

```bash
ssh root@YOUR_SERVER_PUBLIC_IP
```

Or, if you use a sudo-capable user:

```bash
ssh youruser@YOUR_SERVER_PUBLIC_IP
```

---

## 📦 Step 4 — Clone the Repository

```bash
sudo apt update
sudo apt install -y git

git clone https://github.com/cempack/standard-notes-project.git
cd standard-notes-project
```

---

## ⚙️ Step 5 — Run the Installer

```bash
chmod +x install.sh
sudo ./install.sh
```

The installer is **interactive** — it will explain each step and prompt you for values.

### Recommended Answers (First Install)

| Prompt | Recommended Value |
|:-------|:------------------|
| Install directory | `/opt/standardnotes` |
| Notes/API domain | `notes.yourdomain.com` |
| Files domain | `files.yourdomain.com` |
| Let's Encrypt certificates | **Yes** |
| Let's Encrypt staging certificates | **No** |
| Enable unattended security updates | **Yes** |
| Configure UFW firewall | **Yes** |
| Disable new user registration now | **No** ⚠️ |
| Install snctl management CLI | **Yes** |
| Auto-grant PRO after first account | Your preference |
| Run initial backup | **Yes** |

> [!WARNING]
> Answer **No** to disabling registration during the first install — unless you've already created your account. You need registration open to create your first Standard Notes account.

> [!TIP]
> If you answer **Yes** to the automatic first-account flow, the installer will wait after services start. Open Standard Notes, register the email you entered, and the CLI will grant server-side `PRO_PLAN` automatically.

### What the Installer Does

The installer will automatically:

- Install Docker, Nginx, Certbot, Fail2ban, UFW, Go, and backup tools
- Generate secure Standard Notes secrets
- Write `/opt/standardnotes/.env`
- Set `PUBLIC_FILES_SERVER_URL=https://files.yourdomain.com`
- Configure HTTPS Nginx reverse proxy
- Start the Standard Notes Docker Compose stack
- Install the dashboard
- Install the `snctl` management CLI
- Optionally wait for your first account, grant server-side `PRO_PLAN`, and lock registration
- Configure scheduled backups
- Print verification commands and next steps

---

## ✅ Step 6 — Verify the Installation

Run these commands to confirm everything is working:

**Check HTTPS endpoints:**

```bash
curl -I https://notes.yourdomain.com
curl -I https://files.yourdomain.com
```

**Check Docker containers:**

```bash
cd /opt/standardnotes
docker compose ps
```

**Run the health checker:**

```bash
sudo /opt/standardnotes/scripts/healthcheck.sh
```

**Run the guided test script:**

```bash
sudo /opt/standardnotes/scripts/test.sh
```

> [!TIP]
> All four checks should pass. If any fail, jump to [Step 16 — Troubleshooting](#-step-16--troubleshooting) below.

---

## 🛠 Step 7 — Use the Management CLI (`snctl`)

If you chose to install it, `snctl` is available globally:

```bash
snctl help
```

### Command Reference

| Command | Description |
|:--------|:------------|
| `snctl status` | Show container and service status |
| `snctl health` | Run a full health check |
| `snctl logs server` | Tail Standard Notes server logs |
| `snctl backup` | Run an on-demand backup |
| `snctl update` | Pull latest images & restart |
| `snctl registration-status` | Check if registration is open or locked |
| `snctl lock-registration` | Disable new account registration |
| `snctl unlock-registration` | Re-enable account registration |
| `snctl first-account EMAIL` | Full first-account setup flow |
| `snctl grant-pro EMAIL --wait` | Grant server-side PRO subscription |

### First-Account Flow (Recommended)

The easiest way to set up your first account:

```bash
snctl first-account you@example.com
```

This single command will:

1. Open registration
2. Print your sync server URL
3. Wait for you to register `you@example.com` in the Standard Notes app
4. Grant server-side `PRO_USER` / `PRO_PLAN`
5. Ask whether to lock registration afterward

---

## 📊 Step 8 — Open the Dashboard

Navigate to:

```
https://notes.yourdomain.com/dashboard/
```

Log in with the dashboard username and password you set during installation.

**The dashboard shows:**

- ✅ Standard Notes API health
- ✅ Files server health
- ✅ Public HTTPS checks
- 📁 Latest backup status
- 📄 Recent logs

---

## 📱 Step 9 — Configure the Standard Notes App

Open the Standard Notes desktop or mobile app, then:

1. Go to **Account menu** → **Advanced options** → **Sync Server** → **Custom**
2. Set the custom sync server to:
   ```
   https://notes.yourdomain.com
   ```
3. **Register** your first account
4. Create a test note and confirm it syncs
5. Test file uploads if you use Standard Notes file features

> [!IMPORTANT]
> Set the sync server to exactly `https://notes.yourdomain.com` — do **not** append `/dashboard` or any other path.

---

## 🔐 Step 10 — Lock Registration

After your first account exists, disable public registration to prevent unauthorized sign-ups.

**Option A — Using `snctl`:**

```bash
snctl lock-registration
```

**Option B — Re-run the installer:**

```bash
cd /opt/standardnotes
sudo ./install.sh
```

When prompted, answer **Yes** to disabling new user registration.

---

## ⭐ Step 11 — Grant Server-Side PRO Subscription

Standard Notes documents a self-hosted database change for granting your account a server-side `PRO_PLAN` subscription. This repo includes a helper script for that.

**Using `snctl` (recommended):**

```bash
snctl grant-pro you@example.com --wait
```

**Or using the helper script directly:**

```bash
sudo /opt/standardnotes/scripts/grant-pro-subscription.sh --wait you@example.com
```

This grants:

- `PRO_USER` role
- `PRO_PLAN` subscription with a far-future expiry

> [!WARNING]
> **Client-side vs. Server-side features:**
>
> - ✅ This unlocks **server-side** premium features on your self-hosted server.
> - ❌ It does **not** unlock **client-side** premium features such as Super notes or Nested tags in official apps.
> - 🔑 For full client-side premium features, Standard Notes requires an **offline plan**.

> [!NOTE]
> The helper validates the email, checks the user exists, checks the `PRO_USER` role exists, and is safe to re-run for the same user.

<details>
<summary>📋 <strong>Manual SQL equivalent (click to expand)</strong></summary>

From your working directory (`/opt/standardnotes`):

```bash
docker compose exec db sh -c "MYSQL_PWD=\$MYSQL_ROOT_PASSWORD mysql \$MYSQL_DATABASE -e \
  'INSERT INTO user_roles (role_uuid , user_uuid) VALUES ((SELECT uuid FROM roles WHERE name=\"PRO_USER\" ORDER BY version DESC limit 1) ,(SELECT uuid FROM users WHERE email=\"EMAIL@ADDR\")) ON DUPLICATE KEY UPDATE role_uuid = VALUES(role_uuid);' \
"

docker compose exec db sh -c "MYSQL_PWD=\$MYSQL_ROOT_PASSWORD mysql \$MYSQL_DATABASE -e \
  'INSERT INTO user_subscriptions SET uuid=UUID(), plan_name=\"PRO_PLAN\", ends_at=8640000000000000, created_at=0, updated_at=0, user_uuid=(SELECT uuid FROM users WHERE email=\"EMAIL@ADDR\"), subscription_id=1, subscription_type=\"regular\";' \
"
```

</details>

---

## 💾 Step 12 — Backups

Backups are scheduled automatically via **systemd timers**.

**Check the backup timer:**

```bash
systemctl list-timers standardnotes-backup.timer --no-pager
```

**Run a manual backup:**

```bash
sudo /opt/standardnotes/scripts/backup.sh
```

**Backup storage location:**

```
/opt/standardnotes/backups/
```

> [!CAUTION]
> Backups contain **sensitive data**, including the database and `.env` secrets. Always copy them off-server securely (e.g. via `scp` or encrypted transfer).

---

## 🔄 Step 13 — Restore from Backup

1. Copy your backup archive and `.sha256` file to the server
2. Run the restore script:

```bash
sudo /opt/standardnotes/scripts/restore.sh /path/to/standardnotes-backup-YYYYmmddTHHMMSSZ.tar.gz
```

3. When prompted, type `RESTORE` to confirm
4. After restore completes, verify with:

```bash
sudo /opt/standardnotes/scripts/healthcheck.sh
```

---

## 🆙 Step 14 — Update Standard Notes

**Using the update helper (recommended):**

```bash
sudo /opt/standardnotes/scripts/update.sh
```

The update script will:

1. Run a backup
2. Pull new Docker images
3. Restart containers
4. Run a health check

<details>
<summary>📋 <strong>Manual update steps (click to expand)</strong></summary>

```bash
sudo /opt/standardnotes/scripts/backup.sh
cd /opt/standardnotes
docker compose pull
docker compose up -d
sudo /opt/standardnotes/scripts/healthcheck.sh
```

</details>

---

## 📋 Step 15 — Common Commands Reference

| Task | Command |
|:-----|:--------|
| View container status | `cd /opt/standardnotes && docker compose ps` |
| View Standard Notes logs | `cd /opt/standardnotes && docker compose logs -f server` |
| View Nginx error logs (notes) | `sudo tail -f /var/log/nginx/standardnotes-error.log` |
| View Nginx error logs (files) | `sudo tail -f /var/log/nginx/standardnotes-files-error.log` |
| Restart Standard Notes | `cd /opt/standardnotes && sudo docker compose up -d` |
| Test & reload Nginx | `sudo nginx -t && sudo systemctl reload nginx` |
| Check Fail2ban status | `sudo fail2ban-client status` |
| Check dashboard service | `sudo systemctl status standardnotes-dashboard` |
| View dashboard logs | `sudo journalctl -u standardnotes-dashboard -n 100 --no-pager` |

---

## 🔧 Step 16 — Troubleshooting

<details>
<summary>🔴 <strong>Docker Hub rate limit error during install</strong></summary>

If you see `"You have reached your unauthenticated pull rate limit"`:

The installer automatically retries up to 3 times with backoff and offers to run `docker login`. If it still fails:

1. Create a **free** Docker Hub account at [hub.docker.com/signup](https://hub.docker.com/signup)
2. Log in: `docker login`
3. Rerun: `sudo ./install.sh`

> **Tip**
> Free authenticated accounts get **200 pulls per 6 hours** vs. 100 for anonymous.

</details>

<details>
<summary>🔴 <strong>HTTPS is not working</strong></summary>

Run these diagnostic commands:

```bash
curl -I http://notes.yourdomain.com
curl -I https://notes.yourdomain.com
sudo nginx -t
sudo systemctl status nginx
```

Common causes:
- DNS not yet propagated
- Ports 80/443 not open in cloud firewall
- Certbot failed to issue certificates (check with `sudo certbot certificates`)

</details>

<details>
<summary>🔴 <strong>Nginx returns 502 Bad Gateway</strong></summary>

The backend container is likely not running or not ready:

```bash
cd /opt/standardnotes
docker compose ps
docker compose logs --tail=200 server
curl -sS -o /dev/null -w '%{http_code}\n' http://127.0.0.1:3000
curl -sS -o /dev/null -w '%{http_code}\n' http://127.0.0.1:3125
```

If containers are restarting, check logs for errors. The server container can take 30–60 seconds to become ready after startup.

</details>

<details>
<summary>🔴 <strong>Standard Notes client cannot sync</strong></summary>

Work through this checklist:

- [ ] Sync server is set to exactly `https://notes.yourdomain.com` (no trailing path)
- [ ] Do **not** include `/dashboard` or any extra path
- [ ] Certificates are trusted (not staging/self-signed)
- [ ] All containers are running: `docker compose ps`
- [ ] `.env` has the correct files URL:

```bash
grep '^PUBLIC_FILES_SERVER_URL=' /opt/standardnotes/.env
```

</details>

---

## 🚀 Step 17 — Quick Start (Copy & Paste)

For the impatient — here's the entire flow in one block. Replace the domains with your real domains when the installer prompts you.

```bash
# Install & launch
sudo apt update
sudo apt install -y git

git clone https://github.com/cempack/standard-notes-project.git
cd standard-notes-project
chmod +x install.sh
sudo ./install.sh

# Verify
sudo /opt/standardnotes/scripts/healthcheck.sh
```

Then configure your Standard Notes app with:

```
https://notes.yourdomain.com
```

---

<div align="center">

**📝 Standard Notes Self-Hosting Project**

[GitHub Repository](https://github.com/cempack/standard-notes-project) · [Standard Notes](https://standardnotes.com)

*Your notes. Your server. Your privacy.*

</div>
