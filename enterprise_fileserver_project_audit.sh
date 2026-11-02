#!/usr/bin/env bash
# Secure Enterprise Linux File Server with Automated Backup
# SAFE AUDIT SCRIPT for the EXISTING Ubuntu VirtualBox project.
# Run inside Ubuntu, not Windows PowerShell.
# It checks current configuration and saves records. It does NOT recreate users,
# overwrite smb.conf, reset passwords, change firewall rules, or alter networking.

set -u
BASE="/srv/enterprise-fileserver"
SHARED="$BASE/shared"
BACKUPS="$BASE/backups"
LOGS="$BASE/logs"
BACKUP_SCRIPT="$BASE/scripts/backup.sh"
RECORDS="$HOME/enterprise-fileserver-records"

line() { printf '%s\n' '------------------------------------------------------------'; }
ok() { printf '[OK] %s\n' "$*"; }
warn() { printf '[CHECK] %s\n' "$*"; }
fail() { printf '[ERROR] %s\n' "$*"; }

clear
line
echo "SECURE ENTERPRISE LINUX FILE SERVER"
echo "Automated Backup - Existing Project Audit"
line
echo "This script checks the current setup; it will not rebuild it."
echo "Some checks may ask for your Ubuntu sudo password."
echo

# 1. Project folders
printf '\n1. PROJECT DIRECTORIES\n'
for p in "$BASE" "$SHARED/dev" "$SHARED/hr" "$SHARED/finance" "$BACKUPS" "$LOGS"; do
  if [[ -d "$p" ]]; then ok "Exists: $p"; else fail "Missing: $p"; fi
done

# 2. Department groups and accounts
printf '\n2. USERS AND GROUPS\n'
for g in dev hr finance; do
  if getent group "$g" >/dev/null; then ok "Group exists: $g"; getent group "$g"; else fail "Group missing: $g"; fi
done
for u in devuser hruser financeuser; do
  if id "$u" >/dev/null 2>&1; then ok "User exists: $u"; id "$u"; else fail "User missing: $u"; fi
done

# 3. Folder ownership and permissions
printf '\n3. DEPARTMENT PERMISSIONS\n'
for p in "$SHARED/dev" "$SHARED/hr" "$SHARED/finance"; do
  [[ -d "$p" ]] && stat -c '%A (%a) %U:%G %n' "$p"
done

# 4. Samba configuration validation
printf '\n4. SAMBA CONFIGURATION\n'
if command -v testparm >/dev/null; then
  sudo testparm -s
  [[ $? -eq 0 ]] && ok "Samba configuration checked." || fail "Samba configuration has an error."
else
  fail "testparm not installed."
fi

# 5. Samba service and TCP 445 listener
printf '\n5. SAMBA SERVICE AND PORT\n'
systemctl is-active smbd && ok "Samba service active." || fail "Samba service not active."
systemctl is-enabled smbd && ok "Samba enabled at boot." || warn "Samba not enabled at boot."
sudo ss -lntp | grep -E '(:445[[:space:]]|:445$)' || warn "No TCP 445 listener found."

# 6. SSH and firewall status
printf '\n6. SSH AND FIREWALL\n'
systemctl is-active ssh && ok "SSH service active." || warn "SSH inactive or service name differs."
sudo ufw status verbose

# 7. Backup script syntax, log and archives
printf '\n7. BACKUP SCRIPT AND LOG\n'
if [[ -x "$BACKUP_SCRIPT" ]]; then
  ok "Executable backup script found: $BACKUP_SCRIPT"
  bash -n "$BACKUP_SCRIPT" && ok "Backup script syntax is valid." || fail "Backup script syntax check failed."
else
  fail "Backup script missing or not executable: $BACKUP_SCRIPT"
fi
if [[ -f "$LOGS/backup.log" ]]; then sudo tail -n 15 "$LOGS/backup.log"; else warn "Backup log missing."; fi

printf '\n8. BACKUP ARCHIVES\n'
shopt -s nullglob
archives=("$BACKUPS"/enterprise-backup-*.tar.gz)
shopt -u nullglob
if (( ${#archives[@]} )); then
  ls -lh --time-style=long-iso "${archives[@]}"
  newest="$(ls -1t "$BACKUPS"/enterprise-backup-*.tar.gz 2>/dev/null | head -n 1)"
  if [[ -n "$newest" ]] && tar -tzf "$newest" >/dev/null; then ok "Newest archive verified: $newest"; else fail "Newest archive verification failed."; fi
else
  warn "No backup archives found."
fi

# 9. Cron schedule and service
printf '\n9. AUTOMATED BACKUP SCHEDULE\n'
sudo crontab -l 2>/dev/null || warn "No root crontab found."
systemctl is-active cron && ok "Cron service active." || warn "Cron service inactive."

# 10. Guest network information and known deployment design
printf '\n10. UBUNTU NETWORK INFORMATION\n'
hostname
hostname -I
ip -brief address 2>/dev/null || ip address
echo "Known VirtualBox NAT forwarding: host 127.0.0.1:2222 -> guest TCP 22."
echo "Known Samba forwarding: host 127.0.0.1:1445 -> guest TCP 445."
echo "Windows portproxy was configured: 127.0.0.1:445 -> 127.0.0.1:1445."
echo "Windows SMB authentication is still unconfirmed."

# 11. Save copies of key files and status
printf '\n11. SAVE PROJECT RECORDS\n'
mkdir -p "$RECORDS"
{
  echo "Secure Enterprise Linux File Server - Status Report"
  date
  echo
  echo "Hostname and IP:"
  hostname
  hostname -I
  echo
  echo "Samba service:"
  systemctl is-active smbd 2>&1
  echo
  echo "Project tree:"
  if command -v tree >/dev/null; then sudo tree -pug "$BASE"; else find "$BASE" -maxdepth 4 -print; fi
} > "$RECORDS/project-status-report.txt" 2>&1
[[ -f /etc/samba/smb.conf ]] && sudo cp /etc/samba/smb.conf "$RECORDS/smb.conf"
[[ -f "$BACKUP_SCRIPT" ]] && sudo cp "$BACKUP_SCRIPT" "$RECORDS/backup.sh"
[[ -f "$LOGS/backup.log" ]] && sudo cp "$LOGS/backup.log" "$RECORDS/backup.log"
if command -v tree >/dev/null; then sudo tree -pug "$BASE" > "$RECORDS/project-tree.txt" 2>&1; fi
sudo chown -R "$USER":"$(id -gn)" "$RECORDS"
ok "Records saved to $RECORDS"

# 12. Optional local Samba authentication test
printf '\n12. OPTIONAL LOCAL SAMBA LOGIN TEST\n'
read -r -p "Test devuser login now? Type y or n: " answer
case "$answer" in
  y|Y)
    if command -v smbclient >/dev/null; then
      smbclient //localhost/Development -U devuser
      rc=$?
      if (( rc == 0 )); then ok "Local Samba test completed."; else fail "Local Samba login failed. Fix this before Windows testing."; fi
    else
      fail "smbclient is not installed."
    fi
    ;;
  *) echo "Skipped local Samba login test." ;;
esac

line
echo "AUDIT FINISHED"
echo "Records folder: $RECORDS"
echo "Windows deployment is NOT complete until Windows can authenticate and open a department share."
echo "This script did not reset passwords or change server/network settings."
line
