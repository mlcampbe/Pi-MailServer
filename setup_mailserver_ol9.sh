#!/bin/bash
set -e

# ----------------------------
# Variables - UPDATE THESE
# ----------------------------
MAILHOST="mail.x.com"
DOMAIN="${MAILHOST#*.}"
SMTPUSER="xxxx"
SMTPPASS="xxxx"
ADMINEMAIL="xxxx"
RSPAMDPASS="xxxx"
SPAMHAUSKEY="xxxx"
MAILDIR="/mnt/mailserver"
POSTMASTERPASS="xxxx"
MY_IP="99.x.x.x"

# ----------------------------
# OS Preparation & Repos
# ----------------------------
hostnamectl set-hostname $MAILHOST

echo "Installing Repositories..."
dnf install -y oracle-epel-release-el9
dnf config-manager --set-enabled ol9_codeready_builder
sudo dnf config-manager --enable ol9_developer_EPEL
curl -sSL https://rspamd.com/rpm-stable/centos-9/rspamd.repo | tee /etc/yum.repos.d/rspamd.repo

echo "Installing Packages..."
dnf install -y \
postfix \
dovecot dovecot-pigeonhole \
rspamd redis \
certbot \
fail2ban \
unbound \
curl \
policycoreutils-python-utils

systemctl stop postfix || true
systemctl stop dovecot || true

# ----------------------------
# FIREWALL (Firewalld) and SELINUX PORTS
# ----------------------------
echo "Configuring OS Firewall..."
systemctl enable --now firewalld

# Use port numbers to avoid 'service not found' errors on OL9
firewall-cmd --permanent --add-service=ssh
firewall-cmd --permanent --add-service=smtp
firewall-cmd --permanent --add-service=http
firewall-cmd --permanent --add-port=587/tcp  # Submission
firewall-cmd --permanent --add-port=465/tcp  # SMTPS
firewall-cmd --permanent --add-port=993/tcp  # IMAPS
firewall-cmd --reload

semanage port -a -t dns_port_t -p tcp 5353
semanage port -a -t dns_port_t -p udp 5353
semanage port -a -t http_port_t -p tcp 11334

# ----------------------------
# TLS CERTIFICATE
# ----------------------------
echo "Generating TLS certificate..."
certbot certonly --standalone \
-d $MAILHOST -d $DOMAIN \
--agree-tos \
-m $ADMINEMAIL \
--non-interactive

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
# Allow Antivirus/Rspamd to scan the system
# ----------------------------
setsebool -P antivirus_can_scan_system 1
semanage fcontext -a -t mail_spool_t "$MAILDIR(/.*)?"
restorecon -Rv $MAILDIR

# ----------------------------
# POSTFIX (Relay via SMTP2GO)
# ----------------------------
echo "Configuring Postfix..."
cat > /etc/postfix/main.cf <<EOF
# Global Settings
compatibility_level = 3.10
myhostname = mail.$DOMAIN
mydomain = $DOMAIN
myorigin = \$mydomain

# Network Settings
inet_interfaces = all
inet_protocols = ipv4
mydestination = \$myhostname, localhost.\$mydomain, localhost
mynetworks = 127.0.0.0/8
relay_domains =
append_dot_mydomain = no

# User Settings
virtual_mailbox_domains = $DOMAIN
virtual_transport = lmtp:unix:private/dovecot-lmtp
virtual_alias_maps = hash:/etc/postfix/virtual

# TLS/SSL Security
smtpd_tls_auth_only = yes
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
smtp_tls_CAfile = /etc/pki/tls/certs/ca-bundle.crt

# Postscreen (Anti-Spam)
postscreen_dnsbl_sites =
    $SPAMHAUSKEY.zen.dq.spamhaus.net*3
    bl.spamcop.net*2
    b.barracudacentral.org*2
postscreen_dnsbl_threshold = 3
postscreen_dnsbl_action = enforce
postscreen_pipelining_enable = yes
postscreen_pipelining_action = enforce
postscreen_non_smtp_command_enable = yes
postscreen_non_smtp_command_action = enforce
postscreen_bare_newline_enable = yes
postscreen_bare_newline_action = enforce
postscreen_access_list = permit_mynetworks

queue_directory = /var/spool/postfix
meta_directory = /etc/postfix
setgid_group = postdrop
command_directory = /usr/sbin
sample_directory = /usr/share/doc/postfix/samples
newaliases_path = /usr/bin/newaliases
mailq_path = /usr/bin/mailq
readme_directory = /usr/share/doc/postfix/README_FILES
sendmail_path = /usr/sbin/sendmail
mail_owner = postfix
daemon_directory = /usr/libexec/postfix
manpage_directory = /usr/share/man
html_directory = no
data_directory = /var/lib/postfix
shlib_directory = /usr/lib64/postfix
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

cat >> /etc/postfix/virtual <<EOF
postmaster@$DOMAIN mike@$DOMAIN
EOF
postmap /etc/postfix/virtual

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
sed -i "s|^#[[:space:]]mail_location =.*|mail_location = maildir:$MAILDIR/%n/Maildir|" /etc/dovecot/conf.d/10-mail.conf

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
passdb {
  driver = passwd-file
  args = /etc/dovecot/postfix_accounts.cf
}

userdb {
  driver = static
  args = uid=5000 gid=5000 home=/mnt/mailserver/%n
}
EOF

sed -i 's|^!include auth-system.conf.ext|#!include auth-system.conf.ext|' /etc/dovecot/conf.d/10-auth.conf
sed -i 's|^#!include auth-passwdfile.conf.ext|!include auth-passwdfile.conf.ext|' /etc/dovecot/conf.d/10-auth.conf
sed -i 's|#sieve_before =.*|sieve_before = /etc/dovecot/sieve/move-to-junk.sieve|' /etc/dovecot/conf.d/90-sieve.conf
sed -i 's|^[[:space:]]*# (sieve_extensions = \+notify \+imapflags)$|\1 +editheader|' /etc/dovecot/conf.d/90-sieve.conf
sed -i 's|^[[:blank:]]*#[[:blank:]]*mail_plugins|  mail_plugins|' /etc/dovecot/conf.d/20-imap.conf
sed -i 's/^[[:blank:]]*#[[:blank:]]*mail_plugins = \$mail_plugin/  mail_plugins = \$mail_plugins sieve/' /etc/dovecot/conf.d/20-lmtp.conf
sed -i 's|^[[:blank:]]*#[[:blank:]]*mail_plugins|  mail_plugins|' /etc/dovecot/conf.d/15-lda.conf

#sed -i "/#mailbox Spam {/,/^[[:blank:]]*#}/ {
#    s/^[[:blank:]]*#//
#    s/^[[:blank:]]*//
#}" /etc/dovecot/conf.d/90-sieve.conf

#sed -i "/#imapsieve_from Spam {/,/^[[:blank:]]*#}/ {
#    s/^[[:blank:]]*#//
#    s/^[[:blank:]]*//
#}" /etc/dovecot/conf.d/90-sieve.conf

mkdir /etc/dovecot/sieve
semanage fcontext -a -t dovecot_etc_t "/etc/dovecot/sieve(/.*)?"
restorecon -Rv /etc/dovecot/sieve
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
ssl_cert = < /etc/letsencrypt/live/$MAILHOST/fullchain.pem
ssl_key = < /etc/letsencrypt/live/$MAILHOST/privkey.pem
ssl_min_protocol = TLSv1.2
ssl_prefer_server_ciphers = yes
disable_plaintext_auth = yes
EOF

# Auto-create standard IMAP folders
sed -i "/mailbox Junk {/a \    auto = subscribe" /etc/dovecot/conf.d/15-mailboxes.conf
sed -i "/mailbox Drafts {/a \    auto = subscribe" /etc/dovecot/conf.d/15-mailboxes.conf
sed -i "/mailbox Trash {/a \    auto = subscribe" /etc/dovecot/conf.d/15-mailboxes.conf
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
bind_socket = "127.0.0.1:11334";
secure_ip = "127.0.0.1, $MY_IP";
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
    rbl = "$SPAMHAUSKEY.dq.spamhaus.net";
    checks = ["from", "received"];
    symbol = "RBL_SPAMHAUS";
  }

  spamcop {
    rbl = "bl.spamcop.net";
    checks = ["from"];
    symbol = "RBL_SPAMCOP";
  }

  barracuda {
    rbl = "b.barracudacentral.org";
    checks = ["from"];
    symbol = "RBL_BARRACUDA";
  }
}
EOF

cat > /etc/rspamd/local.d/groups.conf <<EOF
symbols {
  "RBL_SPAMHAUS" {
    weight = 6.0;
  }

  "RBL_SPAMCOP" {
    weight = 2.5;
  }

  "RBL_BARRACUDA" {
    weight = 2.0;
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
extended_spam_headers = true;
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
sed -i 's/^# save 3600 1/save 3600 1/' /etc/redis/redis.conf
sed -i 's/^# save 300 100/save 300 100/' /etc/redis/redis.conf
sed -i 's/^# save 60 10000/save 60 10000/' /etc/redis/redis.conf
sed -i 's/^appendonly no/appendonly yes/' /etc/redis/redis.conf
systemctl restart redis

# ----------------------------
# FAIL2BAN
# ----------------------------
echo "Configuring Fail2ban..."
cat > /etc/fail2ban/jail.local <<EOF
[DEFAULT]
bantime  = 1h
findtime = 10m
maxretry = 5

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
cat > /etc/unbound/conf.d/pi.conf <<EOF
server:
    interface: 127.0.0.1
    port: 5353
    access-control: 127.0.0.0/8 allow
    do-ip6: no
EOF

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
# CREATE POSTMASTER ACCOUNT
# ----------------------------
./add_user postmaster $POSTMASTERPASS

# ----------------------------
# START SERVICES
# ----------------------------
echo "Restarting Services..."
systemctl enable --now redis rspamd postfix dovecot fail2ban unbound

echo ""
echo "INSTALL COMPLETE"
echo "DKIM record available in /var/lib/rspamd/dkim/$DOMAIN.txt"
echo "Ready to send/receive mail via $MAILHOST"
echo ""
echo "Create new mail users using the add_user.sh file:"
echo "sudo ./add_user.sh user@$DOMAIN 'password'"
