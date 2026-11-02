#!/usr/bin/env bash
#
# ##  SERVER SETUP SCRIPT  ##
#
# Sets up a fresh Debian server (installed with only "SSH server" and
# "standard system utilities") to run services in Docker, and joins it to
# your Tailscale tailnet so you can SSH in from anywhere.
#
# Usage (as your normal user):
#   sudo bash bootstrap.sh
#
# Requires Debian to have been installed as described in README.md, with the
# root password left blank, so your user already has sudo. Your user is not
# added to the 'docker' group, so Docker is managed with 'sudo docker ...'.
#
# Optional environment variables:
#   TS_AUTHKEY   Tailscale auth key for unattended login. If unset, the script
#                prints a login URL you open on any device instead.
#   TS_HOSTNAME  Name of this machine in your tailnet (default: system hostname)
#   REPO_URL     Git URL of this repository (default set below)
#
# Email alerts: the script asks for your SMTP settings at the start. They are
# stored only on the server in /etc/msmtprc (readable by root only), never in
# this repo. Press Enter at the first question to skip email alerts.
# To change them later: sudo RECONFIGURE_EMAIL=1 bash bootstrap.sh

set -euo pipefail
IFS=$'\n\t'

# ---------- Configuration ----------
REPO_URL="${REPO_URL:-https://github.com/YOUR_GITHUB_USER/homeserver.git}"
REPO_DIR="/opt/homeserver"        # git clone of this repo (code only, no secrets)
CONTAINERS_DIR="/opt/containers"  # runtime data: .env files, volumes, state
TS_HOSTNAME="${TS_HOSTNAME:-$(hostname)}"

log()  { printf '\n==> %s\n' "$*"; }
warn() { printf '\n!!  %s\n' "$*" >&2; }

# ---------- Pre-flight checks ----------
if [[ "$EUID" -ne 0 || -z "${SUDO_USER:-}" || "$SUDO_USER" == "root" ]]; then
  echo "Error: Run this as your normal user with: sudo bash bootstrap.sh"
  echo "(Debian must be installed as described in README.md, with the root password left blank.)"
  exit 1
fi

# shellcheck source=/dev/null
. /etc/os-release
CODENAME="$VERSION_CODENAME"
ARCH="$(dpkg --print-architecture)"

# ---------- Email alert settings (asked now so the rest runs unattended) ----------
SETUP_EMAIL=false
if [[ -f /etc/msmtprc && "${RECONFIGURE_EMAIL:-0}" != "1" ]]; then
  echo "Email alerts already configured (/etc/msmtprc); keeping existing settings."
elif [[ -t 0 ]]; then
  echo
  echo "Email alerts: the server emails you about disk failures, overheating and full disks."
  echo "Use an app password, ideally for a separate email account used only for sending alerts."
  IFS= read -r -p "SMTP server (e.g. smtp.gmail.com), or Enter to skip: " SMTP_HOST
  if [[ -n "$SMTP_HOST" ]]; then
    IFS= read -r -p "SMTP port [587]: " SMTP_PORT
    SMTP_PORT="${SMTP_PORT:-587}"
    IFS= read -r -p "SMTP username (usually the sending email address): " SMTP_USER
    IFS= read -r -s -p "SMTP password / app password: " SMTP_PASSWORD
    echo
    IFS= read -r -p "Send alerts to [${SMTP_USER}]: " ALERT_TO
    ALERT_TO="${ALERT_TO:-$SMTP_USER}"
    SETUP_EMAIL=true
  else
    echo "Skipping email alerts. Alerts will only be logged (journalctl -t homeserver-alert)."
  fi
else
  warn "No terminal to ask for email settings; skipping email alerts."
fi

# Don't let apt stop for prompt screens
export DEBIAN_FRONTEND=noninteractive

# ---------- Base packages ----------
log "Installing base packages"
apt-get update
apt-get upgrade -y
apt-get install -y --no-install-recommends \
  ca-certificates \
  curl \
  git \
  smartmontools \
  lm-sensors \
  unattended-upgrades \
  htop \
  ncdu \
  sysstat \
  msmtp

# ---------- Third-party apt repositories ----------
log "Adding Docker and Tailscale apt repositories"
install -m 0755 -d /etc/apt/keyrings

# Docker (official repo: current Docker Engine + 'docker compose' plugin)
curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc
chmod a+r /etc/apt/keyrings/docker.asc
echo "deb [arch=${ARCH} signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian ${CODENAME} stable" \
  > /etc/apt/sources.list.d/docker.list

# Tailscale (official repo)
curl -fsSL "https://pkgs.tailscale.com/stable/debian/${CODENAME}.noarmor.gpg" \
  -o /usr/share/keyrings/tailscale-archive-keyring.gpg
curl -fsSL "https://pkgs.tailscale.com/stable/debian/${CODENAME}.tailscale-keyring.list" \
  -o /etc/apt/sources.list.d/tailscale.list

# ---------- Docker ----------
log "Installing Docker"
# Log limits are written before install so Docker starts with them
mkdir -p /etc/docker
cat <<EOF > /etc/docker/daemon.json
{
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "10m",
    "max-file": "3"
  }
}
EOF

apt-get update
apt-get install -y \
  docker-ce \
  docker-ce-cli \
  containerd.io \
  docker-buildx-plugin \
  docker-compose-plugin
systemctl enable --now docker
systemctl restart docker

# Your user is NOT added to the 'docker' group: that group gives root access
# with no password. Manage containers with 'sudo docker ...' instead.

# ---------- Tailscale ----------
log "Installing Tailscale"
apt-get install -y tailscale
systemctl enable --now tailscaled

if tailscale status > /dev/null 2>&1; then
  log "Tailscale is already logged in, skipping login"
elif [[ -n "${TS_AUTHKEY:-}" ]]; then
  log "Logging in to Tailscale with the provided auth key"
  # The key goes through a temporary root-only file so it never appears in
  # the process list or on disk after the script ends.
  KEYFILE="$(mktemp)"
  trap 'rm -f "$KEYFILE"' EXIT
  chmod 600 "$KEYFILE"
  printf '%s' "$TS_AUTHKEY" > "$KEYFILE"
  tailscale up --hostname="$TS_HOSTNAME" --auth-key="file:${KEYFILE}"
  rm -f "$KEYFILE"
else
  log "Logging in to Tailscale: open the URL printed below on any device"
  tailscale up --hostname="$TS_HOSTNAME"
fi

# Keep the Tailscale client updated automatically
tailscale set --auto-update || warn "Could not enable Tailscale auto-update"

# ---------- Monitoring and alerts ----------
log "Configuring monitoring and alerts"

# --- Alert channel ---
# Every alert goes to the journal (view with: journalctl -t homeserver-alert)
# and, if configured, is emailed via msmtp.
if [[ "$SETUP_EMAIL" == true ]]; then
  # msmtp quoting: escape backslashes and double quotes in the password
  esc_pw="${SMTP_PASSWORD//\\/\\\\}"
  esc_pw="${esc_pw//\"/\\\"}"
  if [[ "$SMTP_PORT" == "465" ]]; then STARTTLS=off; else STARTTLS=on; fi

  # umask in a subshell: the file is root-only from the moment it exists
  (
    umask 077
    cat <<EOF > /etc/msmtprc
# Written by bootstrap.sh. Contains credentials: keep root-only, never commit.
defaults
auth           on
tls            on
tls_starttls   ${STARTTLS}
tls_trust_file /etc/ssl/certs/ca-certificates.crt
syslog         LOG_MAIL

account        alerts
host           ${SMTP_HOST}
port           ${SMTP_PORT}
from           ${SMTP_USER}
user           ${SMTP_USER}
password       "${esc_pw}"

account default : alerts
EOF
    mkdir -p /etc/homeserver
    printf 'ALERT_TO="%s"\n' "$ALERT_TO" > /etc/homeserver/notify.conf
  )
  unset SMTP_PASSWORD esc_pw
fi
chown root:root /etc/msmtprc 2> /dev/null && chmod 600 /etc/msmtprc || true

cat <<'EOF' > /usr/local/bin/notify
#!/usr/bin/env bash
# Usage: notify "Title" "Message" [priority: low|default|high]
# Logs to the journal and, if /etc/msmtprc exists, emails ALERT_TO.
set -u
title="${1:-Server alert}"
msg="${2:-}"
prio="${3:-default}"
host="$(hostname)"
logger -t homeserver-alert -p user.warning "${title}: ${msg}"

ALERT_TO=""
# shellcheck source=/dev/null
[[ -r /etc/homeserver/notify.conf ]] && . /etc/homeserver/notify.conf
if [[ -n "$ALERT_TO" && -r /etc/msmtprc ]]; then
  prefix=""
  [[ "$prio" == "high" ]] && prefix="ALERT: "
  {
    printf 'To: %s\n' "$ALERT_TO"
    printf 'Subject: [%s] %s%s\n' "$host" "$prefix" "$title"
    printf 'Date: %s\n' "$(date -R)"
    printf 'Content-Type: text/plain; charset=UTF-8\n\n'
    printf '%s\n\n-- \nSent by %s at %s\n' "$msg" "$host" "$(date '+%F %T')"
  } | msmtp -C /etc/msmtprc -a default "$ALERT_TO" \
    || logger -t homeserver-alert -p user.err "Failed to send alert email (see: journalctl -t msmtp)"
fi
EOF
chmod 755 /usr/local/bin/notify

# --- Temperature sensors ---
# Detects and loads the sensor drivers your hardware needs ('sensors' to view)
sensors-detect --auto > /dev/null || warn "sensors-detect failed; temperature readings may be unavailable"
systemctl restart systemd-modules-load.service || true

# --- Disk health (SMART) ---
# smartd hands its warnings to this hook, which forwards them to 'notify'
cat <<'EOF' > /usr/local/bin/smartd-notify
#!/usr/bin/env bash
exec /usr/local/bin/notify "${SMARTD_SUBJECT:-SMART disk warning}" \
  "${SMARTD_FULLMESSAGE:-${SMARTD_MESSAGE:-No details}}" high
EOF
chmod 755 /usr/local/bin/smartd-notify

# Keep a copy of Debian's default config the first time
[[ -f /etc/smartd.conf.orig ]] || cp /etc/smartd.conf /etc/smartd.conf.orig
cat <<'EOF' > /etc/smartd.conf
# Monitor all disks: health, error logs and attributes (-a)
# Disks may be absent without error (-d removable)
# Warn at 45C, critical at 55C (-W); raise these for SSDs/NVMe, which run hotter
# Short self-test daily at 02:00, long self-test Saturdays at 03:00 (-s)
# Hand warnings to smartd-notify, which logs and emails them (-m/-M)
DEVICESCAN -a -d removable -W 0,45,55 -s (S/../.././02|L/../../6/03) -m <nomailer> -M exec /usr/local/bin/smartd-notify
EOF
# The service is called smartd or smartmontools depending on the Debian release
if systemctl cat smartd.service > /dev/null 2>&1; then SMARTD_UNIT=smartd; else SMARTD_UNIT=smartmontools; fi
systemctl enable "$SMARTD_UNIT" 2> /dev/null || true
systemctl restart "$SMARTD_UNIT"

# --- Resource history (sysstat) ---
# Records CPU, memory, swap, disk I/O and network every 10 minutes.
# View with e.g. 'sar -u' (CPU), 'sar -r' (memory), 'sar -d' (disks), 'sar -u -f /var/log/sysstat/saDD' (past day)
[[ -f /etc/default/sysstat ]] && sed -i 's/^ENABLED=.*/ENABLED="true"/' /etc/default/sysstat
systemctl enable --now sysstat

# --- Health check: CPU temperature and disk space every 5 minutes ---
cat <<'EOF' > /usr/local/bin/health-check
#!/usr/bin/env bash
# Alerts once when a limit is crossed and once when it recovers.
set -uo pipefail

TEMP_LIMIT_C=85     # highest sensor temperature
DISK_LIMIT_PCT=90   # usage of any real filesystem

STATE_DIR=/run/health-check
mkdir -p "$STATE_DIR"

raise() {  # key title message
  [[ -e "$STATE_DIR/$1" ]] && return
  /usr/local/bin/notify "$2" "$3" high
  touch "$STATE_DIR/$1"
}
recover() {  # key title message
  [[ -e "$STATE_DIR/$1" ]] || return
  /usr/local/bin/notify "$2" "$3" low
  rm -f "$STATE_DIR/$1"
}

# Temperature: hottest plausible reading across all hardware sensors
max_temp=0
max_name="unknown"
for f in /sys/class/hwmon/hwmon*/temp*_input; do
  v="$(cat "$f" 2> /dev/null)" || continue
  [[ "$v" =~ ^[0-9]+$ ]] || continue
  v=$((v / 1000))
  (( v > 0 && v < 150 )) || continue
  if (( v > max_temp )); then
    max_temp=$v
    max_name="$(cat "$(dirname "$f")/name" 2> /dev/null || echo unknown)"
  fi
done
if (( max_temp >= TEMP_LIMIT_C )); then
  raise temp "High temperature" "${max_name} is at ${max_temp}C (limit ${TEMP_LIMIT_C}C) on $(hostname)"
elif (( max_temp < TEMP_LIMIT_C - 10 )); then
  recover temp "Temperature normal" "${max_name} back to ${max_temp}C on $(hostname)"
fi

# Disk space: every real (non-virtual) mounted filesystem
while read -r pct target; do
  pct="${pct%\%}"
  [[ "$pct" =~ ^[0-9]+$ ]] || continue
  key="disk${target//\//_}"
  if (( pct >= DISK_LIMIT_PCT )); then
    raise "$key" "Disk almost full" "${target} is ${pct}% full on $(hostname)"
  elif (( pct < DISK_LIMIT_PCT - 5 )); then
    recover "$key" "Disk space OK" "${target} back to ${pct}% on $(hostname)"
  fi
done < <(df --output=pcent,target -x tmpfs -x devtmpfs -x overlay -x squashfs -x efivarfs 2> /dev/null | tail -n +2)
EOF
chmod 755 /usr/local/bin/health-check

cat <<'EOF' > /etc/systemd/system/health-check.service
[Unit]
Description=Check CPU temperature and disk space

[Service]
Type=oneshot
ExecStart=/usr/local/bin/health-check
EOF

cat <<'EOF' > /etc/systemd/system/health-check.timer
[Unit]
Description=Run health-check every 5 minutes

[Timer]
OnBootSec=2min
OnUnitActiveSec=5min

[Install]
WantedBy=timers.target
EOF
systemctl daemon-reload
systemctl enable --now health-check.timer

# ---------- Automatic updates ----------
log "Configuring unattended upgrades"
cat <<EOF > /etc/apt/apt.conf.d/20auto-upgrades
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
EOF

cat <<EOF > /etc/apt/apt.conf.d/50unattended-upgrades-custom
Unattended-Upgrade::Remove-Unused-Dependencies "true";
EOF

# ---------- Laptop lid ----------
sed -i 's/^#\?HandleLidSwitch=.*/HandleLidSwitch=ignore/' /etc/systemd/logind.conf
sed -i 's/^#\?HandleLidSwitchExternalPower=.*/HandleLidSwitchExternalPower=ignore/' /etc/systemd/logind.conf

# ---------- systemd journal size ----------
if grep -q "^#\?SystemMaxUse=" /etc/systemd/journald.conf; then
  sed -i 's/^#\?SystemMaxUse=.*/SystemMaxUse=500M/' /etc/systemd/journald.conf
else
  echo "SystemMaxUse=500M" >> /etc/systemd/journald.conf
fi
systemctl restart systemd-journald

# ---------- Directories and repo ----------
# Both are owned by root: root runs the scripts and compose files in them,
# so a normal user must not be able to change them.
log "Setting up ${CONTAINERS_DIR} and ${REPO_DIR}"
install -d -m 755 -o root -g root "$CONTAINERS_DIR"

if [[ -d "${REPO_DIR}/.git" ]]; then
  git -C "$REPO_DIR" pull --ff-only \
    || warn "Could not update ${REPO_DIR}; continuing"
else
  install -d -m 755 -o root -g root "$REPO_DIR"
  git clone "$REPO_URL" "$REPO_DIR" \
    || warn "Could not clone ${REPO_URL}. Clone it manually into ${REPO_DIR} later."
fi

# ---------- Cleanup ----------
apt-get autoremove -y
apt-get clean

log "Done. Tailscale address of this server:"
tailscale ip -4 || true
echo "SSH in from any device on your tailnet with: ssh ${SUDO_USER}@${TS_HOSTNAME}"

# Confirms the alert channel works end to end
/usr/local/bin/notify "Server online" "Bootstrap finished on $(hostname)" low || true

# This must run last: it applies the lid switch settings
systemctl restart systemd-logind
