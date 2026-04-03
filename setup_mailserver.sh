#!/bin/bash
set -e

# ----------------------------
# Variables
# ----------------------------
# DNS mx record hostname
MAILHOST="mail.domain.com"
DOMAIN="${MAILHOST#*.}"

# Local LAN subnet for full access
LAN_SUBNET="192.168.10.0/24"

# SMTP2GO sending username & password
SMTPUSER="user"
SMTPPASS="pass"

# Email for Certbot notifications
ADMINEMAIL="email"

# Password for the rspamd Web UI
RSPAMDPASS="pass"

# Key for using Free Spamhaus DQS
SPAMHAUSKEY = "key"

# Mail storage location
MAILDIR="/mnt/mailserver"

# Password for postmaster user
POSTMASTER_PASS="pass"

# ----------------------------
# Main script starts here
# Do not change anything below
# ----------------------------

PUBLICIP=$(curl -s ifconfig.me)

echo "Updating system..."
apt update

echo "Installing packages..."
DEBIAN_FRONTEND=noninteractive apt install -y \
postfix \
dovecot-core dovecot-imapd dovecot-pop3d dovecot-sieve dovecot-managesieved dovecot-lmtpd \
rspamd redis-server \
certbot \
fail2ban \
ufw \
unbound \
mailutils curl

systemctl stop postfix
systemctl stop dovecot

# ----------------------------
# TLS CERTIFICATE
# ----------------------------
echo "Generating TLS certificate..."
ufw allow 80
certbot certonly --standalone \
-d $MAILHOST \
--agree-tos \
-m $ADMINEMAIL \
--non-interactive
ufw delete allow 80

# ----------------------------
# Create external mail storage
# ----------------------------
echo "Preparing mail storage at $MAILDIR..."
getent group vmail >/dev/null || groupadd -g 5000 vmail
getent passwd vmail >/dev/null || useradd -g vmail -u 5000 vmail -d "$MAILDIR" -m
mkdir -p $MAILDIR
chown -R vmail:vmail $MAILDIR
chmod 700 $MAILDIR

# ----------------------------
# POSTFIX CONFIG
# ----------------------------
echo "Configuring Postfix..."
# Generate the postfix_accounts.cf file and the postmaster account
HASHED_PASS=$(doveadm pw -s SHA512-CRYPT -p $POSTMASTER_PASS)
echo "postmaster:${HASHED_PASS}" > /etc/dovecot/postfix_accounts.cf
mkdir -p $MAILDIR/postmaster/Maildir
chown -R vmail:vmail $MAILDIR/postmaster
chown root:dovecot /etc/dovecot/postfix_accounts.cf
chmod 640 /etc/dovecot/postfix_accounts.cf

cat > /etc/postfix/main.cf <<EOF
# Global Settings
compatibility_level = 3.10
myhostname = $MAILHOST
mydomain = $DOMAIN
myorigin = \$mydomain

# Network Settings
inet_interfaces = all
inet_protocols = ipv4
mydestination = \$myhostname, localhost.\$mydomain, localhost
mynetworks = 127.0.0.0/8, 192.168.0.0/16
relay_domains = \$mydestination
append_dot_mydomain = yes
respectful_logging = yes

# User Settings
virtual_mailbox_domains = $DOMAIN
virtual_transport = lmtp:unix:private/dovecot-lmtp
home_mailbox = Maildir/
# Since we want system users to use "regular mail" (local /etc/passwd),
# we remove mailbox_transport so it doesn't go to Dovecot.
# mailbox_transport = lmtp:unix:private/dovecot-lmtp

# TLS/SSL Security
smtpd_tls_cert_file=/etc/letsencrypt/live/$MAILHOST/fullchain.pem
smtpd_tls_key_file=/etc/letsencrypt/live/$MAILHOST/privkey.pem
smtpd_tls_security_level = may
smtp_tls_security_level = encrypt

# Modern protocol restrictions (disabling SSLv2, SSLv3, TLS 1.0, and TLS 1.1)
smtpd_tls_mandatory_protocols = !SSLv2, !SSLv3, !TLSv1, !TLSv1.1
smtpd_tls_protocols = !SSLv2, !SSLv3, !TLSv1, !TLSv1.1
smtp_tls_mandatory_protocols = !SSLv2, !SSLv3, !TLSv1, !TLSv1.1
smtp_tls_protocols = !SSLv2, !SSLv3, !TLSv1, !TLSv1.1

# SASL Authentication
smtpd_sasl_auth_enable = yes
smtpd_sasl_type = dovecot
smtpd_sasl_path = private/auth

# HELO Restrictions
smtpd_helo_required = yes
smtpd_helo_restrictions =
    permit_mynetworks
    permit_sasl_authenticated
    reject_invalid_helo_hostname
    reject_non_fqdn_helo_hostname

# Relay Restrictions (Modern Postfix logic)
smtpd_relay_restrictions =
    permit_mynetworks,
    permit_sasl_authenticated,
    defer_unauth_destination

# Recipient Restrictions & RBLs
smtpd_recipient_restrictions =
    permit_sasl_authenticated
    permit_mynetworks
    reject_unauth_destination
    reject_rbl_client $SPAMHAUSKEY.zen.spamhaus.org
    reject_rbl_client bl.spamcop.net
    reject_rbl_client b.barracudacentral.org

# Rate Limiting
smtpd_client_connection_rate_limit = 30
smtpd_client_message_rate_limit = 20
smtpd_client_connection_count_limit = 10

# Milter / Rspamd Settings
milter_protocol = 6
milter_default_action = accept
smtpd_milters = inet:127.0.0.1:11332
non_smtpd_milters = inet:127.0.0.1:11332

# Outbound Relay (SMTP2GO)
relayhost = [mail.smtp2go.com]:587
smtp_sasl_auth_enable = yes
smtp_sasl_password_maps = hash:/etc/postfix/sasl_passwd
smtp_sasl_security_options = noanonymous
smtp_tls_CAfile = /etc/ssl/certs/ca-certificates.crt

# Postscreen (Anti-Spam)
postscreen_dnsbl_sites =
    $SPAMHAUSKEY.zen.spamhaus.org*1
    bl.spamcop.net
    b.barracudacentral.org
postscreen_dnsbl_threshold = 2
postscreen_dnsbl_action = enforce
EOF

sed -i '/^smtp[[:space:]]\+inet.*smtpd$/ s/^/#/' /etc/postfix/master.cf
sed -i '/^#smtp[[:space:]]\+inet.*postscreen$/ s/^#//' /etc/postfix/master.cf
sed -i '/^#smtpd[[:space:]]\+pass.*smtpd$/ s/^#//' /etc/postfix/master.cf
sed -i '/^#dnsblog[[:space:]]\+unix.*dnsblog$/ s/^#//' /etc/postfix/master.cf
sed -i '/^#tlsproxy[[:space:]]\+unix.*tlsproxy$/ s/^#//' /etc/postfix/master.cf

cat >> /etc/postfix/master.cf <<EOF
submission inet n - y - - smtpd
 -o smtpd_tls_security_level=encrypt
 -o smtpd_sasl_auth_enable=yes
 -o smtpd_recipient_restrictions=permit_sasl_authenticated,reject
 -o smtpd_milters=inet:127.0.0.1:11332
 -o non_smtpd_milters=inet:127.0.0.1:11332
EOF

# ----------------------------
# SMTP2GO AUTH
# ----------------------------
echo "Configuring SMTP2GO relay..."
cat > /etc/postfix/sasl_passwd <<EOF
[mail.smtp2go.com]:587 $SMTPUSER:$SMTPPASS
EOF
postmap /etc/postfix/sasl_passwd
chmod 600 /etc/postfix/sasl_passwd
chmod 600 /etc/postfix/sasl_passwd.db

# ----------------------------
# DOVECOT CONFIG
# ----------------------------
echo "Configuring Dovecot..."
sed -i 's/^#protocols =.*/protocols = imap lmtp sieve/' /etc/dovecot/dovecot.conf

sed -i "s|^mail_driver.*|mail_driver = maildir|" /etc/dovecot/conf.d/10-mail.conf
sed -i "s|^\(mail_home[[:space:]]*=[[:space:]]*\)/home|\1$MAILDIR|" /etc/dovecot/conf.d/10-mail.conf
sed -i "s|^mail_path[[:space:]]*=[[:space:]]*.*|mail_path = $MAILDIR/%{user \| username}/Maildir|" /etc/dovecot/conf.d/10-mail.conf
sed -i "s|^mail_inbox_path.*|#&|" /etc/dovecot/conf.d/10-mail.conf

cat > /etc/dovecot/conf.d/15-custom.conf <<EOF
service lmtp {
  unix_listener /var/spool/postfix/private/dovecot-lmtp {
    mode = 0660
    user = postfix
    group = postfix
  }
}
service auth {
  unix_listener auth-userdb {
    #mode = 0666
    #user =
    #group =
  }
  # Postfix smtp-auth
  unix_listener /var/spool/postfix/private/auth {
   mode = 0660
   user = postfix
   group = postfix
 }
}
EOF

cat > /etc/dovecot/conf.d/auth-passwdfile.conf.ext <<EOF
passdb passwd-file {
  driver = passwd-file
  passwd_file_path = /etc/dovecot/postfix_accounts.cf
}

userdb static {
  driver = static
  fields {
    uid=5000
    gid=5000
    home=$MAILDIR/%{user | username}
  }
}
EOF

sed -i 's/^#auth_mechanisms = plain login/auth_mechanisms = plain login/' /etc/dovecot/conf.d/10-auth.conf
sed -i 's/^!include auth-system.conf.ext/#!include auth-system.conf.ext/' /etc/dovecot/conf.d/10-auth.conf
sed -i 's/^#!include auth-passwdfile.conf.ext/!include auth-passwdfile.conf.ext/' /etc/dovecot/conf.d/10-auth.conf

# Setup sieve filtering
sed -i "/#sieve_script default {/,/#}/ {
    s/^#//
    s/type = default/type = before/
    s|path = /etc/dovecot/sieve/default/|path = /etc/dovecot/sieve/move-to-junk.sieve|
}" /etc/dovecot/conf.d/90-sieve.conf

#sed -i "/#mailbox Spam {/,/^[[:blank:]]*#}/ {
#    s/^[[:blank:]]*#//
#    s/^[[:blank:]]*//
#}" /etc/dovecot/conf.d/90-sieve.conf

#sed -i "/#imapsieve_from Spam {/,/^[[:blank:]]*#}/ {
#    s/^[[:blank:]]*#//
#    s/^[[:blank:]]*//
#}" /etc/dovecot/conf.d/90-sieve.conf

sed -i "/protocol imap {/,/}/ {
    s/^[[:blank:]]*#[[:blank:]]*mail_plugins/  mail_plugins/
    s/^[[:blank:]]*#[[:blank:]]*imap_sieve/    imap_sieve/
    s/^[[:blank:]]*#[[:blank:]]*}/  }/
}" /etc/dovecot/conf.d/20-imap.conf

sed -i "/protocol lmtp {/,/}/ {
    s/^[[:blank:]]*#[[:blank:]]*mail_plugins/  mail_plugins/
    s/^[[:blank:]]*#[[:blank:]]*sieve/    sieve/
    s/^[[:blank:]]*#[[:blank:]]*}/  }/
}" /etc/dovecot/conf.d/20-lmtp.conf
sed -i 's/^\s*auth_username_format = %{user | username | lower}/  # &/' /etc/dovecot/conf.d/20-lmtp.conf

sed -i "/protocol lda {/,/}/ {
    s/^[[:blank:]]*#[[:blank:]]*mail_plugins/  mail_plugins/
    s/^[[:blank:]]*#[[:blank:]]*sieve/    sieve/
    s/^[[:blank:]]*#[[:blank:]]*}/  }/
}" /etc/dovecot/conf.d/15-lda.conf

mkdir /etc/dovecot/sieve
cat > /etc/dovecot/sieve/move-to-junk.sieve <<EOF
require ["fileinto"];
if anyof (
    header :contains "Subject" "***SPAM***",
    header :contains "X-Spam-Status" "Yes",
    header :contains "X-Spam-Flag" "YES"
) {
    fileinto "Junk";
}
EOF
sievec /etc/dovecot/sieve/move-to-junk.sieve

# TLS
cat > /etc/dovecot/conf.d/10-ssl.conf <<EOF
ssl = required
ssl_server_cert_file = /etc/letsencrypt/live/$MAILHOST/fullchain.pem
ssl_server_key_file = /etc/letsencrypt/live/$MAILHOST/privkey.pem
ssl_min_protocol = TLSv1.2
EOF

# Auto-create standard IMAP folders
sed -i "/mailbox Junk {/a \    auto = subscribe" /etc/dovecot/conf.d/15-mailboxes.conf
sed -i "/mailbox Drafts {/a \    auto = subscribe" /etc/dovecot/conf.d/15-mailboxes.conf
sed -i "/mailbox Trash {/a \    auto = subscribe" /etc/dovecot/conf.d/15-mailboxes.conf
sed -i "/mailbox Sent {/a \    auto = subscribe" /etc/dovecot/conf.d/15-mailboxes.conf
sed -i "/mailbox Sent Messages {/a \    auto = subscribe" /etc/dovecot/conf.d/15-mailboxes.conf

# ----------------------------
# RSPAMD CONFIG
# ----------------------------
echo "Configuring Rspamd..."
mkdir -p /etc/rspamd/local.d
mkdir -p /var/lib/rspamd/dkim

# Redis backend
cat > /etc/rspamd/local.d/redis.conf <<EOF
servers = "127.0.0.1:6379";
EOF

# Dashboard + controller with LAN secure_ip
HASHED_PASS=$(rspamadm pw -p "$RSPAMDPASS" -q)
cat > /etc/rspamd/local.d/worker-controller.inc <<EOF
bind_socket = "0.0.0.0:11334";
secure_ip = "127.0.0.1, $LAN_SUBNET";
password = "$HASHED_PASS";
enable_password = "$HASHED_PASS";
EOF

# ----------------------------
# DISABLE SENDERSCORE
# ----------------------------
cat > /etc/rspamd/local.d/rbl.conf <<EOF
rbls {
  senderscore {
    enabled = false;
  }
  senderscore_reputation {
    enabled = false;
  }
  spamhaus {
    # Replace the bracketed part with your actual key
    rbl = "$SPAMHAUSKEY.zen.dq.spamhaus.net";
    enabled = true;
  }
}
EOF

# ----------------------------
# DKIM
# ----------------------------
rspamadm dkim_keygen -d $DOMAIN -s default -k /var/lib/rspamd/dkim/$DOMAIN.key
cat > /etc/rspamd/local.d/dkim_signing.conf <<EOF
domain {
 $DOMAIN {
  path = "/var/lib/rspamd/dkim/$DOMAIN.key";
  selector = "default";
 }
}
EOF

# ----------------------------
# GREYLIST
# ----------------------------
cat > /etc/rspamd/local.d/greylist.conf <<EOF
enabled = true;
use_score = true
timeout = 5m;
expire = 1d;
EOF

# ----------------------------
# REPUTATION
# ----------------------------
cat > /etc/rspamd/local.d/reputation.conf <<EOF
backend = "redis";
expire = 7d;
EOF

# ----------------------------
# BAYES
# ----------------------------
cat > /etc/rspamd/local.d/classifier-bayes.conf <<EOF
backend = "redis";
min_tokens = 11;
min_learns = 20;
autolearn = true;
statfile { symbol = "BAYES_SPAM"; spam = true; }
statfile { symbol = "BAYES_HAM"; spam = false; }
EOF

# ----------------------------
# FUZZY FILTER
# ----------------------------
cat > /etc/rspamd/local.d/fuzzy_check.conf <<EOF
servers = "127.0.0.1:11335";
symbol = "FUZZY_DENIED";
max_score = 20.0;
read_only = no;
EOF

cat > /etc/rspamd/local.d/worker-fuzzy.inc <<EOF
bind_socket = "127.0.0.1:11335";
backend = "redis";
expire = 90d;
fuzzy_map {
 spam { max_score = 20.0; }
 ham { max_score = 2.0; }
}
EOF

# ----------------------------
# NEURAL FILTER
# ----------------------------
cat > /etc/rspamd/local.d/neural.conf <<EOF
servers = "127.0.0.1:6379";
max_profiles = 1;
train {
  max_trains = 1000;
  max_usages = 20;
}
profile "default" {
  redis_key = "neural";
  hidden_layer = 20;
  learning_rate = 0.01;
  max_iterations = 25;
}
EOF

# ----------------------------
# OPTIONS CONFIG
# ----------------------------
cat > /etc/rspamd/local.d/options.inc <<EOF
dns {
    nameserver = ["127.0.0.1:5353"];
    timeout = 2s;
    retransmits = 2;
}
EOF

# ----------------------------
# HEADER CONFIG
# ----------------------------
cat > /etc/rspamd/local.d/actions.conf <<EOF
no_action = 0;
add_header = 2.0;
rewrite_subject = 7.0;
greylist = 4.0;
reject = 50.0;
EOF

cat > /etc/rspamd/local.d/milter.conf <<EOF
discard_on_reject = false;
quarantine_on_reject = false;
EOF

cat > /etc/rspamd/local.d/milter_headers.conf <<EOF
use = ["x-spam-status", "spam-header", "x-spamd-bar", "authentication-results"];
extended_spam_headers = false;
skip_local = false;
skip_authenticated = true;
routines {
  "x-spam-status" {
    header = "X-Spam-Status";
    value = "\$is_spam, score=\$score threshold=\$required_score";
    remove = 1;
  }
  "spam-header" {
    header = "X-Spam-Flag";
    value = "YES";
    remove = 1;
  }
  "x-spamd-bar" {
    header = "X-Spamd-Bar";
    remove = 1;
  }
  "authentication-results" {
    header = "Authentication-Results";
    remove = 1;
  }
}
EOF

# ----------------------------
# RSPAMD Permissions
# ----------------------------
echo "Fixing Rspamd permissions..."
chown -R _rspamd:_rspamd /var/lib/rspamd
chmod -R 750 /var/lib/rspamd
chmod 600 /var/lib/rspamd/dkim/*.key 2>/dev/null || true
chown _rspamd:_rspamd /var/lib/rspamd/dkim/*.key 2>/dev/null || true
chown -R root:_rspamd /etc/rspamd
chmod -R 750 /etc/rspamd

# ----------------------------
# REDIS PERSISTENCE
# ----------------------------
echo "Configuring Redis for persistent storage..."
sed -i 's/^# save 900 1/save 900 1/' /etc/redis/redis.conf
sed -i 's/^# save 300 10/save 300 10/' /etc/redis/redis.conf
sed -i 's/^# save 60 10000/save 60 10000/' /etc/redis/redis.conf
sed -i 's/^# appendonly no/appendonly yes/' /etc/redis/redis.conf
systemctl restart redis-server

# ----------------------------
# FAIL2BAN
# ----------------------------
echo "Configuring Fail2ban..."
cat > /etc/fail2ban/jail.local <<EOF
[dovecot]
enabled = true

[postfix]
enabled = true

[postfix-sasl]
enabled = true
EOF

# ----------------------------
# UNBOUND
# ----------------------------
echo "Configuring Unbound..."
cat > /etc/unbound/unbound.conf.d/pi.conf <<EOF
server:
    interface: 127.0.0.1
    port: 5353
    access-control: 127.0.0.0/8 allow
    do-ip6: no
EOF

# ----------------------------
# FIREWALL
# ----------------------------
echo "Configuring Firewall..."
ufw allow 25
ufw allow 587
ufw allow 993
ufw allow from $LAN_SUBNET
ufw --force enable

# ----------------------------
# TLS RENEW HOOK
# ----------------------------
echo "Configuring Let's Encrypt Renewal..."
mkdir -p /etc/letsencrypt/renewal-hooks/deploy
cat > /etc/letsencrypt/renewal-hooks/deploy/reload-mail.sh <<EOF
#!/bin/bash
systemctl reload postfix
systemctl reload dovecot
EOF
chmod +x /etc/letsencrypt/renewal-hooks/deploy/reload-mail.sh

# ----------------------------
# START SERVICES
# ----------------------------
echo "Restarting Services..."
systemctl enable redis-server rspamd postfix dovecot fail2ban unbound
systemctl restart unbound
systemctl restart redis-server
systemctl restart rspamd
systemctl restart postfix
systemctl restart dovecot
systemctl restart fail2ban

echo ""
echo "INSTALL COMPLETE"
echo "DKIM record available in /var/lib/rspamd/dkim/$DOMAIN.txt"
echo "Rspamd dashboard available at http://<Pi-IP>:11334 for LAN: $LAN_SUBNET"
echo "Ready to send/receive mail via $MAILHOST"
echo ""
echo "Create new mail users using the add_user.sh file:"
echo "sudo ./add_user.sh user@$DOMAIN 'password'"
