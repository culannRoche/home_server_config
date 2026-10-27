#! /usr/bin/env bash

set -euo pipefail

IFS=$'\n\t'
TARGET_USER="${SUDO_USER:-$USER}"   

INSTALL_DIR="/opt/containers/tailscale"
TARGET_USER="${SUDO_USER:-$USER}"

mkdir -p "${INSTALL_DIR}/state"

# Tailscale config file
cat << 'EOF' > "${INSTALL_DIR}/docker-compose.yml"
services:
  tailscale:
    image: tailscale/tailscale:latest
    container_name: tailscale-node
    hostname: debian-server-node
    network_mode: host
    cap_add:
      - NET_ADMIN
      - NET_RAW
    volumes:
      - ./state:/var/lib/tailscale
      - /dev/net/tun:/dev/net/tun
    environment:
      - TS_AUTHKEY=${TS_AUTHKEY}
      - TS_STATE_DIR=/var/lib/tailscale
    restart: unless-stopped
EOF

# Paste Tailscale Key here
cat << 'EOF' > "${INSTALL_DIR}/.env.template"
TS_AUTHKEY=tskey-auth-YOUR_KEY_HERE
EOF

cat << 'EOF' > "${INSTALL_DIR}/.gitignore"
.env
state/
EOF

if [[ ! -f "${INSTALL_DIR}/.env" ]]; then
  cp "${INSTALL_DIR}/.env.template" "${INSTALL_DIR}/.env"
  echo "==> Created local .env template file."
fi
