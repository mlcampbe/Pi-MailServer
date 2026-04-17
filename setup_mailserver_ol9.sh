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
firewall-cmd --permanent --add-service=http
firewall-cmd --permanent --add-service=smtp
firewall-cmd --permanent --add-port=587/tcp  # Submission
firewall-cmd --permanent --add-port=993/tcp  # IMAPS
firewall-cmd --reload

semanage port -a -t dns_port_t -p tcp 5353
semanage port -a -t dns_port_t -p udp 5353
semanage port -a -t http_port_t -p tcp 11334
semanage port -a -t http_port_t -p tcp 11335

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

# SMTP Sender Restrictions
smtpd_sender_restrictions =
    permit_mynetworks
    permit_sasl_authenticated
    reject_non_fqdn_sender
    reject_unknown_sender_domain

# Rate Limiting
smtpd_client_connection_rate_limit = 30
smtpd_client_message_rate_limit = 20
smtpd_client_connection_count_limit = 10
smtpd_client_recipient_rate_limit = 50

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
# Disabled to allow rspamd to handle dnsbl
#postscreen_dnsbl_sites =
#    byskvcgo5cf6un4qdu5e5tfyza.zen.dq.spamhaus.net*3
#    bl.spamcop.net*2
#    b.barracudacentral.org*2
#postscreen_dnsbl_threshold = 4
#postscreen_dnsbl_action = enforce
postscreen_greet_action = enforce
postscreen_pipelining_enable = yes
postscreen_pipelining_action = enforce
postscreen_non_smtp_command_enable = yes
postscreen_non_smtp_command_action = enforce
postscreen_bare_newline_enable = yes
postscreen_bare_newline_action = enforce
postscreen_access_list = permit_mynetworks, cidr:/etc/postfix/postscreen_access.cidr

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
virtual_alias_maps = hash:/etc/postfix/virtual
EOF

cat >> /etc/postfix/postscreen_access.cidr <<EOF
# Google/Gmail Whitelist
209.85.0.0/16      permit
74.125.0.0/16      permit
66.249.0.0/16      permit
64.233.0.0/16      permit
172.217.0.0/16     permit
173.194.0.0/16     permit
108.177.0.0/16     permit

# Microsoft 365 / Outlook / Exchange Online
40.92.0.0/15      permit
40.107.0.0/16     permit
52.100.0.0/14     permit
104.47.0.0/17     permit

# Apple iCloud Mail
17.0.0.0/8        permit
57.103.64.0/18    permit
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
sed -i "s|^#mail_location =.*|mail_location = maildir:$MAILDIR/%n/Maildir|" /etc/dovecot/conf.d/10-mail.conf

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

sed -i 's|^[[:blank:]]*#[[:blank:]]*mail_plugins = \$mail_plugins|  mail_plugins = \$mail_plugins imap_sieve|' /etc/dovecot/conf.d/20-imap.conf
sed -i 's|^[[:blank:]]*#imap_id_send =|imap_id_send = name "Mail Server"|' /etc/dovecot/conf.d/20-imap.conf
sed -i 's|^[[:blank:]]*#[[:blank:]]*mail_plugins = \$mail_plugins|  mail_plugins = \$mail_plugins sieve|' /etc/dovecot/conf.d/20-lmtp.conf
sed -i 's|^[[:blank:]]*#[[:blank:]]*mail_plugins|  mail_plugins|' /etc/dovecot/conf.d/15-lda.conf
sed -i 's|^[[:blank:]]*#[[:blank:]]*port = 143|    port = 0|' /etc/dovecot/conf.d/10-master.conf
sed -i 's|^[[:blank:]]*#[[:blank:]]*port = 110|    port = 0|' /etc/dovecot/conf.d/10-master.conf
sed -i 's|^[[:blank:]]*#[[:blank:]]*port = 995|    port = 0|' /etc/dovecot/conf.d/10-master.conf
sed -i 's|^!include auth-system.conf.ext|#!include auth-system.conf.ext|' /etc/dovecot/conf.d/10-auth.conf
sed -i 's|^#!include auth-passwdfile.conf.ext|!include auth-passwdfile.conf.ext|' /etc/dovecot/conf.d/10-auth.conf
sed -i 's|^[[:blank:]]*#[[:blank:]]*auth_cache_size = 0|auth_cache_size = 1M|' /etc/dovecot/conf.d/10-auth.conf
sed -i 's|^[[:blank:]]*#[[:blank:]]*auth_cache_ttl = 1 hour|auth_cache_ttl = 1 hour|' /etc/dovecot/conf.d/10-auth.conf
sed -i 's|^[[:blank:]]*#[[:blank:]]*auth_cache_negative_ttl = 1 hour|auth_cache_negative_ttl = 1 hour|' /etc/dovecot/conf.d/10-auth.conf
sed -i 's|#sieve_before =.*|sieve_before = /etc/dovecot/sieve/move-to-junk.sieve|' /etc/dovecot/conf.d/90-sieve.conf
sed -i 's|^[[:blank:]]*#[[:blank:]]*sieve_extensions = +notify +imapflags|  sieve_extensions = +notify +imapflags +editheader +vnd.dovecot.pipe|' /etc/dovecot/conf.d/90-sieve.conf
sed -i 's|^[[:blank:]]*#sieve_global_extensions =.*|  sieve_global_extensions = +vnd.dovecot.pipe +vnd.dovecot.execute|' /etc/dovecot/conf.d/90-sieve.conf
sed -i 's|^[[:blank:]]*#sieve_plugins =.*|  sieve_plugins = sieve_imapsieve sieve_extprograms|' /etc/dovecot/conf.d/90-sieve.conf
sed -i '$d' /etc/dovecot/conf.d/90-sieve.conf
cat >>/etc/dovecot/conf.d/90-sieve.conf <<EOF

  # When moving TO Junk
  sieve_pipe_bin_dir = /usr/bin

  # Triggered when moving to the folder with the 'Junk' special-use attribute
  imapsieve_mailbox1_name = Junk
  imapsieve_mailbox1_causes = COPY
  imapsieve_mailbox1_before = file:/etc/dovecot/sieve/learn-spam.sieve

  # Triggered when moving FROM Junk to any other folder
  imapsieve_mailbox2_name = *
  imapsieve_mailbox2_from = Junk
  imapsieve_mailbox2_causes = COPY
  imapsieve_mailbox2_before = file:/etc/dovecot/sieve/learn-ham.sieve
}
EOF

sed -i "/inet_listener submission {/,/}/ {
    s/^[[:blank:]]*#[[:blank:]]*port = 587/     port = 587/
}" /etc/dovecot/conf.d/10-master.conf

sed -i -e '/#service managesieve-login {/ s/^#//' -e '/vsz_limit = 64M/{n; s/^#//}' /etc/dovecot/conf.d/20-managesieve.conf
sed -i -e '/inet_listener sieve {/ s/^[[:blank:]]*#[[:blank:]]*/  /' \
       -e '/port = 4190/ s/^[[:blank:]]*#[[:blank:]]*port = 4190/    port = 0/' \
       -e '/inet_listener sieve {/,/}/ { /^[[:blank:]]*#[[:blank:]]*}/ s/^[[:blank:]]*#[[:blank:]]*/  / }' /etc/dovecot/conf.d/20-managesieve.conf

# Sieve file setup
mkdir -p /etc/dovecot/sieve
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

cat > /etc/dovecot/sieve/learn-spam.sieve <<EOF
require ["vnd.dovecot.pipe", "copy", "imapsieve", "environment", "variables"];

if anyof (environment :is "imap.cause" "COPY", environment :is "imap.cause" "APPEND") {
    pipe :copy "rspamc" ["-P", "$RSPAMDPASS", "learn_spam"];
}
EOF
sievec /etc/dovecot/sieve/learn-spam.sieve

cat > /etc/dovecot/sieve/learn-ham.sieve <<EOF
require ["vnd.dovecot.pipe", "copy", "imapsieve", "environment", "variables"];

if anyof (environment :is "imap.cause" "COPY", environment :is "imap.cause" "APPEND") {
    pipe :copy "rspamc" ["-P", "$RSPAMDPASS", "learn_ham"];
}
EOF
sievec /etc/dovecot/sieve/learn-ham.sieve
semanage fcontext -a -t dovecot_etc_t "/etc/dovecot/sieve(/.*)?"
restorecon -Rv /etc/dovecot/sieve

# TLS
cat > /etc/dovecot/conf.d/10-ssl.conf <<EOF
ssl = required
ssl_cert = < /etc/letsencrypt/live/$MAILHOST/fullchain.pem
ssl_key = < /etc/letsencrypt/live/$MAILHOST/privkey.pem
ssl_min_protocol = TLSv1.2
ssl_prefer_server_ciphers = yes
disable_plaintext_auth = yes
ssl_require_crl = no
EOF

# Auto-create standard IMAP folders
sed -i "/mailbox Junk {/a \    auto = subscribe\n    autoexpunge = 90d" /etc/dovecot/conf.d/15-mailboxes.conf
sed -i "/mailbox Drafts {/a \    auto = subscribe" /etc/dovecot/conf.d/15-mailboxes.conf
sed -i "/mailbox Trash {/a \    auto = subscribe\n    autoexpunge = 365d" /etc/dovecot/conf.d/15-mailboxes.conf
sed -i "/mailbox \"Sent Messages\" {/a \    auto = subscribe" /etc/dovecot/conf.d/15-mailboxes.conf

# ----------------------------
# RSPAMD CONFIG
# ----------------------------
echo "Configuring Rspamd..."
mkdir -p /etc/rspamd/local.d
mkdir -p /var/lib/rspamd/dkim

# Dashboard + controller
HASHED_PASS=$(rspamadm pw -p "$RSPAMDPASS" -q)
cat > /etc/rspamd/local.d/worker-controller.inc <<EOF
bind_socket = "127.0.0.1:11334";
secure_ip = "127.0.0.1";
password = "$HASHED_PASS";
enable_password = "$HASHED_PASS";
EOF

# ----------------------------
# LOCAL CONFIGS
# ----------------------------
cat > /etc/rspamd/local.d/redis.conf <<EOF
servers = "127.0.0.1:6379";
EOF

cat > /etc/rspamd/override.d/rbl.conf <<EOF
local_exclude = false;
exclude_users = false;
default_exclude_users = false;

rbls {
  spamhaus {
    enabled = false;
  }
  dbl {
    enabled = false;
  }

  spamhaus_zen {
    symbol = "DQS_ZEN";
    rbl = "$SPAMHAUSKEY.zen.dq.spamhaus.net";
    ipv4 = true;
    ipv6 = true;
    received = true; # Check the full relay chain
    returncodes {
      DQS_ZEN = "127.0.0.0/24";
    }
  }

  spamhaus_dbl {
    symbol = "DQS_DBL";
    rbl = "$SPAMHAUSKEY.dbl.dq.spamhaus.net";
    dkim = true;
    emails = true;
    urls = true;
    returncodes {
      DQS_DBL = "127.0.1.0/24"
    }
  }
}
EOF

cat > /etc/rspamd/override.d/rbl_group.conf <<EOF
symbols {
    "RBL_SPAMHAUS" {
        enabled = false;
    }
    "RECEIVED_RBL_SPAMHAUS" {
        enabled = false;
    }
    "DBL_SPAMHAUS" {
        enabled = false;
    }
}
EOF

cat > /etc/rspamd/local.d/groups.conf <<EOF
group "rbl" {
    symbols {
        "DQS_ZEN" {
            weight = 12.0;
            description = "Spamhaus ZEN IP reputation (SBL/XBL/PBL)";
        }
        "DQS_DBL" {
            weight = 7.0;
            description = "Spamhaus DBL domain reputation";
        }
        "RBL_SPAMCOP" {
          weight = 2.5;
        }
        "RBL_BARRACUDA" {
          weight = 2.0;
        }
    }
}
EOF

rspamadm dkim_keygen -d $DOMAIN -s default -k /var/lib/rspamd/dkim/$DOMAIN.key
cat > /etc/rspamd/local.d/dkim_signing.conf <<EOF
allow_envfrom_empty = false;
domain {
 $DOMAIN {
  path = "/var/lib/rspamd/dkim/$DOMAIN.key";
  selector = "default";
 }
}
EOF

cat > /etc/rspamd/local.d/greylist.conf <<EOF
enabled = true;
use_score = true
timeout = 5min;
expire = 1d;
max_wait = 1h;
EOF

cat > /etc/rspamd/local.d/reputation.conf <<EOF
backend = "redis";
expire = 7d;
EOF

cat > /etc/rspamd/local.d/classifier-bayes.conf <<EOF
backend = "redis";
min_tokens = 11;
min_learns = 20;
autolearn = true;
statfile { symbol = "BAYES_SPAM"; spam = true; }
statfile { symbol = "BAYES_HAM"; spam = false; }
EOF

cat > /etc/rspamd/local.d/fuzzy_check.conf <<EOF
rule "rspamd.com" {
    # Explicitly use only the server you know is working
    servers = "fuzzy2.rspamd.com:11335";
};
EOF

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

cat > /etc/rspamd/local.d/options.inc <<EOF
dns {
    nameserver = ["127.0.0.1:5353"];
    timeout = 2s;
    retransmits = 2;
}
EOF

cat > /etc/rspamd/local.d/actions.conf <<EOF
no_action = 0;
add_header = 6.0;
rewrite_subject = 7.0;
greylist = 4.0;
reject = 25.0;
EOF

cat > /etc/rspamd/local.d/milter.conf <<EOF
discard_on_reject = false;
quarantine_on_reject = false;
EOF

cat > /etc/rspamd/local.d/milter_headers.conf <<EOF
use = ["x-spam-status", "spam-header", "authentication-results"];
extended_spam_headers = false;
skip_local = false;
skip_authenticated = true;
routines {
  "x-spam-status" {
    header = "X-Spam-Status";
    value = "is_spam=\$is_spam, score=\$score threshold=\$required_score";
    remove = 1;
  }
  "spam-header" {
    header = "X-Spam-Flag";
    value = "YES";
    remove = 1;
  }
  "authentication-results" {
    header = "Authentication-Results";
    remove = 1;
  }
}
EOF

cat > /etc/rspamd/local.d/policies_group.conf <<EOF
symbols {
    R_SPF_FAIL { weight = 3.0; }
    R_DKIM_REJECT { weight = 3.0; }
    DMARC_POLICY_REJECT { weight = 6.0; }
    DMARC_POLICY_QUARANTINE { weight = 4.0; }
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
bantime = 24h
findtime = 10m
maxretry = 3
bantime.increment = true
bantime.factor = 2
bantime.max = 1w
#ignoreip = 127.0.0.1/8 ::1 <your-admin-ip>
backend = systemd
usedns = no

[dovecot]
enabled = true
maxretry = 3

[postfix]
enabled = true
maxretry = 5

[postfix-sasl]
enabled = true
maxretry = 3
findtime = 5m

[recidive]
enabled = true
logpath = /var/log/fail2ban.log
bantime = 1w
findtime = 1d
maxretry = 5
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
    prefetch: yes
    cache-min-ttl: 300
    msg-cache-size: 32m
    rrset-cache-size: 64m
EOF

# ----------------------------
# TLS RENEW HOOK
# ----------------------------
echo "Configuring Let's Encrypt Renewal..."
mkdir -p /etc/letsencrypt/renewal-hooks/deploy
cat > /etc/letsencrypt/renewal-hooks/deploy/reload-mail.sh <<EOF
#!/bin/bash
set -e
systemctl reload postfix
systemctl reload dovecot
EOF
chmod +x /etc/letsencrypt/renewal-hooks/deploy/reload-mail.sh

# ----------------------------
# CREATE POSTMASTER ACCOUNT
# ----------------------------
./add_user.sh postmaster@$DOMAIN $POSTMASTERPASS

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
echo ""
echo "Remember to setup certbot cron renewal as root using:"
echo "0 */12 * * * /usr/bin/certbot renew --quiet"
