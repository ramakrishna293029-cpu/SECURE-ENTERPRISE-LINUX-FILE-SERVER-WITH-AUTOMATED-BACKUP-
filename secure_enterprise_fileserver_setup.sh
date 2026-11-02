#!/usr/bin/env bash
# Secure Enterprise Linux File Server with Automated Backup
# Idempotent setup/recovery script for Ubuntu. Run from the Ubuntu VM.
# It backs up the current Samba configuration before replacing its share settings.
# It does NOT configure Windows networking; Windows deployment steps are printed at the end.

set -Eeuo pipefail
IFS=$'\n\t'

BASE="/srv/enterprise-fileserver"
SHARED="$BASE/shared"
BACKUPS="$BASE/backups"
LOGS="$BASE/logs"
SCRIPTS="$BASE/scripts"
SMB_CONF="/etc/samba/smb.conf"
STAMP="$(date +%Y%m%d-%H%M%S)"

say() { printf '\n[%s] %s\n' "$(date '+%H:%M:%S')" "$*"; }
die() { printf '\nERROR: %s\n' "$*" >&2; exit 1; }
need_root() { [[ "${EUID}" -eq 0 ]] || die "Run with: sudo bash ~/Downloads/secure_enterprise_fileserver_setup.sh"; }

need_root
[[ -f /etc/os-release ]] || die "This script expects Ubuntu Linux."
# shellcheck disable=SC1091
. /etc/os-release
[[ "${ID:-}" == "ubuntu" ]] || die "Detected ${PRETTY_NAME:-unknown OS}; this script is intended for Ubuntu."

say "1/9 - Install required server utilities"
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y samba smbclient rsync tar cron ufw acl openssh-server

say "2/9 - Create project directories and department groups"
install -d -m 0750 "$BASE" "$BACKUPS" "$LOGS" "$SCRIPTS"
install -d -o root -g dev -m 2770 "$SHARED/dev" 2>/dev/null || true
for grp in dev hr finance; do
    getent group "$grp" >/dev/null || groupadd "$grp"
done
for dept in dev hr finance; do
    install -d -o root -g "$dept" -m 2770 "$SHARED/$dept"
done

say "3/9 - Ensure department login accounts exist"
for user in devuser hruser financeuser; do
    if ! id "$user" >/dev/null 2>&1; then
        useradd -M -s /usr/sbin/nologin "$user"
    fi
done
usermod -aG dev devuser
usermod -aG hr hruser
usermod -aG finance financeuser

say "4/9 - Back up current Samba configuration and write department shares"
if [[ -f "$SMB_CONF" ]]; then
    cp -a "$SMB_CONF" "${SMB_CONF}.before-project-${STAMP}"
fi
cat > "$SMB_CONF" <<'SMBEOF'
[global]
   workgroup = WORKGROUP
   server role = standalone server
   security = user
   map to guest = Bad User
   netbios name = ENTFILESRV
   disable netbios = yes
   logging = file
   log file = /var/log/samba/log.%m
   max log size = 1000
   obey pam restrictions = yes
   unix password sync = yes
   usershare allow guests = no
   server min protocol = SMB2

[Development]
   path = /srv/enterprise-fileserver/shared/dev
   browseable = yes
   read only = no
   valid users = @dev
   force group = dev
   create mask = 0660
   directory mask = 02770

[HR]
   path = /srv/enterprise-fileserver/shared/hr
   browseable = yes
   read only = no
   valid users = @hr
   force group = hr
   create mask = 0660
   directory mask = 02770

[Finance]
   path = /srv/enterprise-fileserver/shared/finance
   browseable = yes
   read only = no
   valid users = @finance
   force group = finance
   create mask = 0660
   directory mask = 02770
SMBEOF

testparm -s >/dev/null || die "Samba configuration validation failed. The previous config backup is in /etc/samba/."
say "Samba configuration is valid."

say "5/9 - Set Samba passwords interactively"
printf '%s\n' "Set a Samba password for each account. Use a temporary password you can type exactly on Windows."
for user in devuser hruser financeuser; do
    while true; do
        read -r -s -p "New Samba password for ${user}: " pass1; printf '\n'
        read -r -s -p "Retype password for ${user}: " pass2; printf '\n'
        if [[ -z "$pass1" ]]; then
            echo "Password cannot be empty. Try again."
        elif [[ "$pass1" != "$pass2" ]]; then
            echo "Passwords did not match. Try again."
        else
            printf '%s\n%s\n' "$pass1" "$pass1" | smbpasswd -s -a "$user" >/dev/null
            unset pass1 pass2
            echo "Samba password set for ${user}."
            break
        fi
        unset pass1 pass2
    done
done

say "6/9 - Install a verified backup script"
cat > "$SCRIPTS/backup.sh" <<'BACKEOF'
#!/usr/bin/env bash
set -Eeuo pipefail
SOURCE="/srv/enterprise-fileserver/shared"
BACKUP_DIR="/srv/enterprise-fileserver/backups"
LOG_DIR="/srv/enterprise-fileserver/logs"
LOG_FILE="$LOG_DIR/backup.log"
TIMESTAMP="$(date +'%Y-%m-%d_%H-%M-%S')"
BACKUP_FILE="$BACKUP_DIR/enterprise-backup-$TIMESTAMP.tar.gz"
mkdir -p "$BACKUP_DIR" "$LOG_DIR"
log() { printf '[%s] %s\n' "$(date '+%F %T')" "$*" >> "$LOG_FILE"; }
cleanup_on_error() { log "ERROR: Backup failed."; rm -f -- "${BACKUP_FILE:-}"; }
trap cleanup_on_error ERR
for dept in dev hr finance; do
    [[ -d "$SOURCE/$dept" ]] || { log "ERROR: Missing $SOURCE/$dept"; exit 1; }
done
log "Backup started"
tar -czf "$BACKUP_FILE" -C "$SOURCE" dev hr finance
tar -tzf "$BACKUP_FILE" >/dev/null
log "SUCCESS: $BACKUP_FILE"
find "$BACKUP_DIR" -maxdepth 1 -type f -name 'enterprise-backup-*.tar.gz' -mtime +30 -delete
log "Retention cleanup completed"
trap - ERR
printf 'Backup completed and verified: %s\n' "$BACKUP_FILE"
BACKEOF
chmod 0750 "$SCRIPTS/backup.sh"
chown root:root "$SCRIPTS/backup.sh"

say "7/9 - Enable services, firewall rules, and daily backup schedule"
systemctl enable --now smbd
systemctl enable --now ssh
systemctl enable --now cron
# Allow SSH and Samba for this lab VM. For production, restrict these rules to a trusted subnet.
ufw allow OpenSSH >/dev/null
ufw allow Samba >/dev/null
if ! ufw status | grep -q '^Status: active'; then
    ufw --force enable
fi
# Keep the existing root crontab and replace only this project's exact backup line.
( crontab -l 2>/dev/null | grep -Fv "$SCRIPTS/backup.sh" || true
  printf '0 23 * * * %s\n' "$SCRIPTS/backup.sh"
) | crontab -

say "8/9 - Run health checks and create one backup"
systemctl is-active --quiet smbd || die "Samba service is not active."
systemctl is-active --quiet ssh || die "SSH service is not active."
systemctl is-active --quiet cron || die "Cron service is not active."
testparm -s >/dev/null || die "Samba config failed validation."
"$SCRIPTS/backup.sh"
ss -ltn | grep -E ':(22|445)\b' || true
smbclient -L localhost -U devuser
printf '\nDepartment directory permissions:\n'
stat -c '%A %U:%G %n' "$SHARED/dev" "$SHARED/hr" "$SHARED/finance"

say "9/9 - Save project records"
RECORDS="${SUDO_USER:+$(getent passwd "$SUDO_USER" | cut -d: -f6)}/enterprise-fileserver-records"
if [[ "$RECORDS" == "/enterprise-fileserver-records" || -z "$RECORDS" ]]; then
    RECORDS="/root/enterprise-fileserver-records"
fi
mkdir -p "$RECORDS"
cp -f "$SMB_CONF" "$RECORDS/smb.conf"
cp -f "$SCRIPTS/backup.sh" "$RECORDS/backup.sh"
cp -f "$LOGS/backup.log" "$RECORDS/backup.log" 2>/dev/null || true
find "$BASE" -maxdepth 4 -printf '%M %u:%g %p\n' > "$RECORDS/project-tree.txt"
chown -R "${SUDO_USER:-root}":"$(id -gn "${SUDO_USER:-root}" 2>/dev/null || echo root)" "$RECORDS" 2>/dev/null || true

cat <<'DONE'

============================================================
UBUNTU FILE SERVER SETUP FINISHED
============================================================
Local checks performed:
- Samba configuration validated
- Samba, SSH, and cron services enabled
- Department groups and shares configured
- Samba passwords set interactively
- A backup was created and archive-verified
- Daily backup scheduled for 23:00
- Project records saved

WINDOWS DEPLOYMENT (run these in Windows PowerShell as Administrator,
NOT in Ubuntu):
1. Confirm VirtualBox NAT port forwarding remains:
   Host 127.0.0.1:2222 -> Guest port 22
   Host 127.0.0.1:1445 -> Guest port 445
2. Confirm the Windows portproxy rule:
   netsh interface portproxy show all
   It should map 127.0.0.1:445 -> 127.0.0.1:1445.
3. Disconnect a previous mapping if one exists:
   net use \\127.0.0.1\Development /delete /y
   (If not found, ignore the message.)
4. Connect with the Samba password just set above:
   net use \\127.0.0.1\Development /user:devuser *
5. To open the share, use File Explorer's address bar:
   \\127.0.0.1\Development

If Windows reports error 86, first test locally in Ubuntu:
   smbclient //localhost/Development -U devuser
Do not repeatedly retry Windows until this local login succeeds.
============================================================
DONE
