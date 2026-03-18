# 📬 Raspberry Pi Mail Server  

### Postfix + Rspamd + Dovecot (Lightweight Self-Hosted Email)

This repository contains a comprehensive Bash script to automate the installation and configuration of a full-featured, secure mail server. It is specifically optimized for **Raspberry Pi** hardware (3B+ or newer) and follows a "local-first" philosophy for home-lab enthusiasts.

---

## Features

* **Core MTA/MDA**: Postfix for routing and Dovecot for IMAP/LMTP delivery.
* **Modern Security**: 
    * Mandatory TLS 1.2+ (disables legacy SSLv2/v3 and TLS 1.0/1.1).
    * Let's Encrypt integration with automated renewal hooks.
    * Fail2Ban for brute-force protection on SMTP and IMAP.
* **Advanced Spam Defense**:
    * **Rspamd**: A high-performance filtering engine using Redis for Bayes learning and neural networks.
    * **Postscreen**: Stops bots at the front door before they hit the heavy SMTP processes.
    * **Sieve**: Server-side rules to automatically move spam to the "Junk" folder.
* **Outbound Delivery**: Pre-configured for **SMTP2GO** relay to ensure high deliverability and avoid residential IP blacklisting.
* **Local Management**: Access the Rspamd Web UI securely from your local LAN.

---

## Prerequisites

* **Hardware**: Raspberry Pi 3B+, 4, or 5.
* **OS**: Debian/Raspberry Pi OS (Bookworm recommended).
* **Domain**: A domain you own with access to DNS records (A, MX, TXT).
* **SMTP2GO Account**: A free or paid account for outbound relaying.

---

## Configuration

Open `setup_mailserver.sh` and update the variables in the **Variables** section:

| Variable | Description |
| :--- | :--- |
| `MAILHOST` | The FQDN of your mail server (e.g., `mail.example.com`). |
| `LAN_SUBNET` | Your local network (e.g., `192.168.1.0/24`) for UI access. |
| `SMTPUSER` | Your SMTP2GO username. |
| `SMTPPASS` | Your SMTP2GO API key or password. |
| `ADMINEMAIL` | Email for Let's Encrypt expiry notifications. |
| `RSPAMDPASS` | Password for the Rspamd Web Dashboard. |
| `MAILDIR` | Where mail is stored (e.g., `/mnt/mailserver` for external drives). |

---

## Installation

1.  **Clone the Repo**:
    ```bash
    git clone [https://github.com/yourusername/pi-mailserver.git](https://github.com/yourusername/pi-mailserver.git)
    cd pi-mailserver
    ```

2.  **Make Executable**:
    ```bash
    chmod +x setup_mailserver.sh
    ```

3.  **Run the Script**:
    ```bash
    sudo ./setup_mailserver.sh
    ```

---

## Post-Installation Steps

1. **DNS Records**:
To ensure your mail isn't rejected by others, you must set up your DNS records:
* **MX Record**: `mail.yourdomain.com` pointing to your IP.
* **DKIM**: Run `cat /var/lib/rspamd/dkim/yourdomain.com.txt` and add the resulting public key as a TXT record in your DNS.
* **SPF**: Add `v=spf1 include:spf.smtp2go.com ~all`.

2. **Manage Users**
The server uses system users. To add a new mailbox:
```bash
$ sudo useradd -d /mnt/mailserver/username -m -s /bin/false username
$ sudo passwd username

3. **Scheduled Backups (3:00 AM)**
Automate your data protection by adding the backup script to the root user's crontab. This triggers a full backup of configs and mail every night at 3:00 AM:
```bash
sudo crontab -e

Append the following line to the bottom of the file:
```bash
0 3 * * * /usr/local/bin/backup_mailserver.sh >> /var/log/mailserver_backup.log 2>&1

[!IMPORTANT]
Network Requirements: Ensure your router/firewall forwards ports 25, 587, and 993 to the server IP. If using UniFi, ensure the "mDNS" feature is enabled if your mail clients are on a different VLAN than the server.
