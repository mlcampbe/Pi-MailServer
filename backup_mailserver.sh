#!/bin/bash

# ----------------------------
# Scheduled with crontab, eg:
# 0 3 * * * /usr/local/bin/mailserver-backup.sh
# ----------------------------

BACKUP_DIR="/mnt/mailserver/backups"
DATE=$(date +%Y-%m-%d)
ARCHIVE="$BACKUP_DIR/mailserver-$DATE.tar.gz"

mkdir -p $BACKUP_DIR

echo "Starting mail server backup..."

tar -czf $ARCHIVE \
/etc/postfix \
/etc/dovecot \
/etc/rspamd \
/etc/redis \
/etc/fail2ban \
/var/lib/rspamd \
/var/lib/redis \
/mnt/mailserver/*/Maildir \
/var/spool/postfix \
2>/dev/null

echo "Backup created: $ARCHIVE"

echo "Removing backups older than 14 days..."

find $BACKUP_DIR -type f -name "mailserver-*.tar.gz" -mtime +14 -delete

echo "Backup completed."
