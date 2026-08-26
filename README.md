# Hosting User Backup Tool

Modern, secure, user-level backup tool for cPanel and DirectAdmin accounts with support for remote storage uploads.

<p align="center">
  <img src="https://img.shields.io/badge/version-1.0.0-blue.svg" />
  <img src="https://img.shields.io/badge/language-Bash-4EAA25.svg" />
  <a href="LICENSE">
    <img alt="License" src="https://img.shields.io/badge/license-MIT-yellow.svg" target="_blank" />
  </a>
</p>

## Description

Hosting User Backup Tool automates **user-level** backups of cPanel and DirectAdmin accounts. It runs directly on the hosting account (no root or WHM reseller access required), triggers the control panel's native full-backup routine, uploads the archive to remote storage (S3 / S3-compatible, FTP/FTPS, or SFTP), and removes the local archive only after the upload is verified. Designed to run silently via cron with optional Telegram notifications.

## Features

- **User-Level Execution** - Runs directly on the hosting account, no root or WHM reseller access needed
- **Multi-Panel Support** - cPanel via official `uapi Backup fullbackup_to_homedir`; DirectAdmin via API and CLI
- **Multi Remote Storage** - Native support for S3 / S3-compatible, FTP / FTPS, and SFTP uploads
- **S3 Signature Support** - AWS Signature V4 (default) and V2 (legacy providers)
- **Auto-Detection** - Detects the control panel, account username (`whoami`), and home directory automatically
- **Verified Uploads** - Compares uploaded byte count with the local file size before deleting the archive
- **Stability-Based Completion** - Waits for the archive and confirms completion via consecutive stable-size polls
- **Telegram Notifications** - Real-time summaries after each backup run
- **Dry Run Mode** - Validates dependencies, configuration, and panel detection without backing up
- **Security-First Design** - 0600 netrc for FTP/SFTP credentials, host-key policy for SFTP, config permission warnings

## Tech Stack

- **Language**: Bash 4+
- **Requirements**: `curl`, `openssl`, `stat`, `find`, `od`, `date`, `awk`, `base64`, `sed`, `tail`, `tr`

## Installation

### Prerequisites

- Bash 4.0 or higher
- Hosting account with SSH / terminal access
- cPanel UAPI or DirectAdmin access on the target panel
- Storage destination with valid credentials

### Steps

1. Clone the repository into your home directory

```bash
cd ~
git clone https://github.com/Akselerasi-Prima-Digital/Hosting-Backup.git backup-tool
cd backup-tool
```

2. Copy and edit the configuration

```bash
cp .env.example .env
nano .env
```

3. Make the script executable

```bash
chmod +x backup.sh
```

4. Validate configuration with a dry run

```bash
./backup.sh --dry-run
```

5. Run the backup

```bash
./backup.sh
```

## Configuration

All configuration is managed via environment variables in the `.env` file.

> **Note**: `.env` values are taken **literally**. Unlike a shell, the loader does not expand `$VAR` or `$(...)`. Keep comments on their own line (anything after `=` is part of the value), and use hardcoded paths if you set them. Leaving path variables blank uses the script's date-based defaults.

### Environment Variables

```bash
# Panel
PANEL_TYPE=auto                          # auto | cpanel | directadmin
# PANEL_USERNAME=your_panel_user         # blank = current user
# PANEL_HOME_DIR=/home/your_panel_user   # blank = $HOME
BACKUP_TIMEOUT_SECONDS=600               # max wait for backup, seconds
BACKUP_POLL_INTERVAL_SECONDS=3
DELETE_LOCAL_AFTER_UPLOAD=true           # delete archive after verified upload
BACKUP_STABLE_CHECKS=2                   # stable-size polls before considered done

# Curl transfer hardening
CURL_CONNECT_TIMEOUT=30
CURL_STALL_TIMEOUT=300                   # abort if <1 KB/s for this long
CURL_RETRIES=2

# Storage type: s3 | ftp | ftps | sftp
STORAGE_TYPE=s3

# Option 1: S3 (when STORAGE_TYPE=s3)
S3_PROTOCOL=https
S3_ENDPOINT=storage.yourserver.com
S3_KEY=your_s3_access_key_here
S3_SECRET=your_s3_secret_key_here
S3_BUCKET=your_bucket_name
# S3_PATH=/your_username/YYYY-MM-DD/    # blank = /username/YYYY-MM-DD/
S3_USE_PATH_STYLE=false                  # true = endpoint/bucket, false = bucket.endpoint
S3_SIGN_VERSION=v4                       # v4 (default) | v2 (legacy)
S3_REGION=us-east-1

# Option 2: FTP / FTPS (when STORAGE_TYPE=ftp or ftps)
FTP_HOST=ftp.yourserver.com
FTP_PORT=21
FTP_USERNAME=ftp_backup_user
FTP_PASSWORD=your_ftp_password
FTP_SSL=true
# FTP_PATH=/backups/your_username/YYYY-MM-DD/

# Option 3: SFTP (when STORAGE_TYPE=sftp)
SFTP_HOST=sftp.yourserver.com
SFTP_PORT=22
SFTP_USERNAME=sftp_backup_user
SFTP_PASSWORD=your_ssh_password
# SFTP_PATH=/backups/your_username/YYYY-MM-DD/
# Disable SSH host-key verification (MITM risk). Set false to enforce host-key checking.
SFTP_INSECURE=true

# DirectAdmin (optional, for DirectAdmin API trigger)
DA_HOST=127.0.0.1
DA_PORT=2222
DA_SSL=true
DA_PASSWORD=your_da_password_or_login_key

# Telegram (optional)
TELEGRAM_BOT_TOKEN=
TELEGRAM_CHAT_ID=

# Logging (empty = console only)
# LOG_FILE=/home/username/logs/backup.log
```

### Panel Settings

| Variable | Description | Default |
|----------|-------------|---------|
| `PANEL_TYPE` | Control panel (`auto`, `cpanel`, `directadmin`) | `auto` |
| `PANEL_USERNAME` | Account username | current user |
| `PANEL_HOME_DIR` | Home directory | `$HOME` |
| `BACKUP_TIMEOUT_SECONDS` | Max wait for backup generation | `600` |
| `BACKUP_POLL_INTERVAL_SECONDS` | Poll interval while waiting | `3` |
| `BACKUP_STABLE_CHECKS` | Stable-size polls before completion | `2` |

### Storage Configuration

#### S3 Storage (`STORAGE_TYPE=s3`)

| Variable | Description | Default |
|----------|-------------|---------|
| `S3_PROTOCOL` | Transfer protocol (`https` or `http`) | `https` |
| `S3_ENDPOINT` | S3-compatible endpoint | `storage.yourserver.com` |
| `S3_KEY` | Access key ID | - |
| `S3_SECRET` | Secret access key | - |
| `S3_BUCKET` | Bucket name | - |
| `S3_PATH` | Object path prefix | `/username/YYYY-MM-DD/` |
| `S3_USE_PATH_STYLE` | Path-style vs virtual-hosted URL | `false` |
| `S3_SIGN_VERSION` | Signature version (`v4` or `v2`) | `v4` |
| `S3_REGION` | SigV4 signing region | `us-east-1` |

Works with Jagoan Storage, AWS S3, Cloudflare R2, Wasabi, MinIO, DigitalOcean Spaces, and other S3-compatible providers. Set `S3_SIGN_VERSION=v2` only for legacy providers that reject V4.

#### FTP / FTPS Storage (`STORAGE_TYPE=ftp` or `ftps`)

| Variable | Description | Default |
|----------|-------------|---------|
| `FTP_HOST` | FTP server hostname | - |
| `FTP_PORT` | FTP port | `21` |
| `FTP_USERNAME` | FTP username | - |
| `FTP_PASSWORD` | FTP password | - |
| `FTP_PATH` | Remote directory | `/backups/username/YYYY-MM-DD/` |
| `FTP_SSL` | Use TLS/SSL (FTPS) | `false` |

#### SFTP Storage (`STORAGE_TYPE=sftp`)

| Variable | Description | Default |
|----------|-------------|---------|
| `SFTP_HOST` | SFTP server hostname | - |
| `SFTP_PORT` | SSH port | `22` |
| `SFTP_USERNAME` | SSH username | - |
| `SFTP_PASSWORD` | SSH password | - |
| `SFTP_PATH` | Remote directory | `/backups/username/YYYY-MM-DD/` |
| `SFTP_INSECURE` | Disable SSH host-key verification | `true` |

### Telegram Setup

1. Get a Bot Token by chatting with @BotFather on Telegram to create a bot
2. Get your Chat ID by chatting with @userinfobot or @myidbot
3. Add the values to `.env`

## Usage

### Run Backup

```bash
./backup.sh
```

### Dry Run

Validate dependencies, configuration, and panel detection without backing up:

```bash
./backup.sh --dry-run
```

### Help

```bash
./backup.sh --help
```

## Cron Setup

1. Place the tool outside `public_html` and secure it

```bash
chmod 700 ~/backup-tool/backup.sh
chmod 600 ~/backup-tool/.env
```

2. Edit crontab

```bash
crontab -e
```

3. Add a cron job (daily at 2 AM)

```cron
0 2 * * * /bin/bash /home/username/backup-tool/backup.sh >> /home/username/backup_cron.log 2>&1
```

## How It Works

1. Loads configuration from `.env` and validates dependencies and storage config
2. Detects the control panel (cPanel via UAPI, DirectAdmin via API or CLI)
3. Triggers the panel's full account backup
4. Polls for the archive, waiting until its size is stable for the configured number of checks
5. Uploads the archive to the configured remote storage
6. Verifies the uploaded byte count matches the local file size
7. Deletes the local archive only when `DELETE_LOCAL_AFTER_UPLOAD=true` and the upload is verified
8. Sends a Telegram summary with the file, size, destination, and duration

## Security

### Implemented Security Features

| Feature | Description |
|---------|-------------|
| **Secure Credential Handling** | FTP/SFTP/DirectAdmin credentials passed via a 0600 netrc file removed on exit, kept out of `ps` |
| **Upload Verification** | Local archive deleted only when the uploaded byte count matches the local file size |
| **Config Permission Warning** | Warns if the `.env` file is readable by group or others |
| **Configurable SFTP Verification** | SFTP host-key check is configurable via `SFTP_INSECURE` (defaults to disabled for convenience) |
| **Dry Run Mode** | Validates configuration without touching remote storage |
| **Portable File Handling** | Binary-safe archive discovery and NUL-separated file listing |

### Security Notes

- **S3 keys**: Unlike the FTP/SFTP credentials, S3 keys must be passed to `openssl` to build the request signature, so they are visible in `ps` to other local users during signing. Run this on a trusted host.
- **SFTP `--insecure`**: With `SFTP_INSECURE=true` (default) SSH host-key verification is disabled, exposing the connection to man-in-the-middle attacks. Set `SFTP_INSECURE=false` and pin the host in `~/.ssh/known_hosts` to enforce verification.

### Security Best Practices

1. **Store outside `public_html`:** Keep the script and `.env` outside web-accessible directories.
2. **Secure file permissions:** Use `chmod 600` on `.env` and `chmod 700` on the script.
3. **Rotate credentials:** Regularly update passwords, tokens, and access keys.
4. **Review logs regularly:** Monitor the backup log for failed operations or suspicious activity.

## Contributing

Contributions are welcome. To contribute:

1. Fork the repository
2. Create a feature branch (`git checkout -b feature/your-feature-name`)
3. Commit your changes (`git commit -m 'Add specific feature'`)
4. Push to the branch (`git push origin feature/your-feature-name`)
5. Open a Pull Request

## License

This project is licensed under the [MIT License](LICENSE).

## Author

Akselerasi Prima Digital