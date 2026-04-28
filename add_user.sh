#!/bin/bash

# Configuration - Must match setup_mailserver.sh
MAILDIR="/mnt/mailserver"
ACCOUNTS_FILE="/etc/dovecot/postfix_accounts.cf"

# Check for root privileges
if [[ $EUID -ne 0 ]]; then
   echo "This script must be run as root"
   exit 1
fi

# Validate input
if [ "$#" -ne 2 ]; then
    echo "Usage: $0 user@domain.com 'password'"
    exit 1
fi

FULL_EMAIL=$1
PASSWORD=$2
USER_PART="${FULL_EMAIL%@*}"

# 1. Generate the hash using Dovecot
echo "Generating password hash..."
HASH=$(doveadm pw -s SHA512-CRYPT -p "$PASSWORD")

# 2. Add to the accounts file
# Logic: Append the full email and hash to the central config
echo "${FULL_EMAIL}:${HASH}" >> "$ACCOUNTS_FILE"

# 3. Create the flat directory structure
# This creates /mnt/mailserver/username/Maildir
echo "Provisioning storage for $USER_PART..."
mkdir -p "$MAILDIR/$USER_PART/Maildir"

# 4. Set permissions
# Ensure the vmail user (UID 5000) owns the new folders
chown -R vmail:vmail "$MAILDIR/$USER_PART"
chmod 700 "$MAILDIR/$USER_PART"

echo "User $FULL_EMAIL added successfully."
echo "Mail location: $MAILDIR/$USER_PART/Maildir"
echo "Remember to add "$FULL_EMAIL OK" to the /etc/postfix/relay_recipients file on the backup mailserver"
echo "and run postmap /etc/postfix/relay_recipients and run systemctl reload postfix"

