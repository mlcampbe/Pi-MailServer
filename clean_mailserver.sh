#!/bin/bash
set -e

echo "======================================"
echo "Mail Server Reset"
echo "======================================"

# Stop services
echo "Stopping services..."

systemctl stop unbound 2>/dev/null || true
systemctl stop postfix 2>/dev/null || true
systemctl stop dovecot 2>/dev/null || true
systemctl stop rspamd 2>/dev/null || true
systemctl stop redis-server 2>/dev/null || true
systemctl stop fail2ban 2>/dev/null || true


# Disable services
systemctl disable unbound 2>/dev/null || true
systemctl disable postfix 2>/dev/null || true
systemctl disable dovecot 2>/dev/null || true
systemctl disable rspamd 2>/dev/null || true
systemctl disable redis-server 2>/dev/null || true
systemctl disable fail2ban 2>/dev/null || true


echo "Removing packages..."

apt purge -y \
postfix postfix-* \
dovecot-core dovecot-* \
rspamd \
redis-server \
fail2ban \
mailutils \
unbound \
certbot


echo "Removing dependencies..."
apt autoremove -y
apt autoclean


echo "Removing configuration directories..."

rm -rf /etc/postfix
rm -rf /etc/dovecot
rm -rf /etc/rspamd
rm -rf /etc/redis
rm -rf /etc/fail2ban
#rm -rf /etc/letsencrypt
rm -rf /etc/unbound/unbound.conf.d


echo "Removing runtime + data directories..."

rm -rf /var/ib/dovecot
rm -rf /var/lib/rspamd
rm -rf /var/lib/redis
rm -rf /var/spool/postfix
rm -rf /var/log/rspamd
rm -rf /var/log/mail.log*
rm -rf /var/log/mail.err*
rm -rf /var/log/mail.warn*


echo "Removing sockets and runtime files..."

rm -rf /run/postfix
rm -rf /run/dovecot
rm -rf /run/rspamd
rm -rf /run/redis


echo "Clearing leftover mail queues..."

postsuper -d ALL 2>/dev/null || true


echo "Resetting firewall mail rules..."

echo y | ufw reset

echo ""
echo "======================================"
echo "Mail Server Reset Complete"
echo "======================================"
echo ""
echo "System is now clean for reinstall."
echo "You can run your install script again."
