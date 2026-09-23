#!/usr/bin/env bash
set -euo pipefail

if [[ $EUID -ne 0 ]]; then
  echo "Run this setup script as root once. The actual backend service runs as the restricted 'nexora' user." >&2
  exit 1
fi

if ! command -v node >/dev/null 2>&1; then
  echo "Node.js 22+ is required before installing Nexora Host." >&2
  exit 1
fi
if ! command -v git >/dev/null 2>&1; then
  apt-get update
  apt-get install -y git
fi

id nexora >/dev/null 2>&1 || useradd --system --create-home --shell /usr/sbin/nologin nexora
mkdir -p /opt/nexora/backend /srv/nexora/data
cp server.mjs package.json /opt/nexora/backend/
if [[ ! -f /opt/nexora/backend/.env ]]; then
  cp .env.example /opt/nexora/backend/.env
fi
cp nexora.service /etc/systemd/system/nexora.service
chown -R nexora:nexora /opt/nexora /srv/nexora
chmod 750 /opt/nexora/backend
chmod 700 /srv/nexora/data
systemctl daemon-reload
systemctl enable nexora.service

echo "Installed Nexora Host backend."
echo "1. Edit /opt/nexora/backend/.env and set NEXORA_OWNER_TOKEN."
echo "2. systemctl restart nexora"
echo "3. Put HTTPS/reverse proxy in front of port 8787 before using it over the internet."
