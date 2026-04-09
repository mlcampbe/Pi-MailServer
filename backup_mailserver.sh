#!/bin/bash

# ----------------------------
# Scheduled with crontab, eg:
# 0 3 * * * /usr/local/bin/backup_mailserver.sh
# ----------------------------

BACKUP_DIR="/mnt/mailserver/backups"
LOG_FILE="/var/log/mailserver_backup.log"
DATE=$(date "+%Y-%m-%d %H:%M:%S")
FILE_DATE=$(date +%Y-%m-%d)
ARCHIVE="$BACKUP_DIR/mailserver-$FILE_DATE.tar.gz"

# Ensure backup directory exists
mkdir -p "$BACKUP_DIR"

# Redirect all subsequent output to the log file
exec >> "$LOG_FILE" 2>&1

echo "-------------------------------------------"
echo "[$DATE] Starting mail server backup..."

# Save redis data
redis-cli save >/dev/null 2>&1

# Create archive
# Note: Using --exclude if there are specific sockets or pipes you want to skip
tar -czf "$ARCHIVE" --exclude="$BACKUP_DIR" \
/etc/postfix \
/etc/dovecot \
/etc/rspamd \
/etc/redis \
/etc/fail2ban \
/etc/unbound \
/etc/letsencrypt \
/var/lib/rspamd \
/var/lib/redis \
/etc/passwd \
/etc/group \
/etc/shadow \
/mnt/mailserver/ \
/var/spool/postfix \
2>/dev/null

if [ $? -eq 0 ]; then
    echo "[$DATE] Backup created successfully: $ARCHIVE"
else
    echo "[$DATE] ERROR: Backup failed!"
fi

echo "[$DATE] Removing backups older than 14 days..."
# Log which files are being deleted
find "$BACKUP_DIR" -type f -name "mailserver-*.tar.gz" -mtime +14 -print -delete

# ----------------------------
# Log Rotation: Keep only the last 1000 lines
# ----------------------------
echo "[$DATE] Truncating log to last 1000 lines..."
tail -n 1000 "$LOG_FILE" > "${LOG_FILE}.tmp" && mv "${LOG_FILE}.tmp" "$LOG_FILE"

echo "[$DATE] Backup completed."
echo "-------------------------------------------"
