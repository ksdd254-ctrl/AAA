#!/usr/bin/env bash
# Puts the Jdo X Abu Qht server on a fresh Ubuntu 22.04 / 24.04 VPS so it runs 24/7:
#   - Node.js 22, the server in /opt/jdo-server, its own system user
#   - systemd keeps it running and restarts it if it ever stops or the VPS reboots
#   - Caddy in front: free HTTPS certificate for your domain, renewed by itself
#   - firewall: only SSH, HTTP and HTTPS open
# Run as root from the folder you uploaded (it must contain src/, package.json, package-lock.json, .env):
#   sudo bash deploy/setup-vps.sh your-domain.com
set -euo pipefail
DOMAIN="${1:?usage: sudo bash deploy/setup-vps.sh your-domain.com   (no domain? use <ip-with-dashes>.sslip.io)}"
SRC="$(cd "$(dirname "$0")/.." && pwd)"
APP=/opt/jdo-server

echo "== packages"
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y curl ca-certificates gnupg debian-keyring debian-archive-keyring apt-transport-https build-essential python3
if ! command -v node >/dev/null || ! node -v | grep -q '^v22'; then
  curl -fsSL https://deb.nodesource.com/setup_22.x | bash -
  apt-get install -y nodejs
fi
if ! command -v caddy >/dev/null; then
  curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
  curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' > /etc/apt/sources.list.d/caddy-stable.list
  apt-get update -y && apt-get install -y caddy
fi

echo "== app files"
id jdo >/dev/null 2>&1 || useradd --system --home "$APP" --shell /usr/sbin/nologin jdo
mkdir -p "$APP"
# code and settings; the database (data/) and the uploaded versions (files/) are only copied the first time
cp -r "$SRC/src" "$SRC/public" "$SRC/package.json" "$SRC/package-lock.json" "$APP/"
[ -f "$APP/.env" ] || cp "$SRC/.env" "$APP/.env"
[ -d "$APP/data" ] || { [ -d "$SRC/data" ] && cp -r "$SRC/data" "$APP/data" || mkdir -p "$APP/data"; }
[ -d "$APP/files" ] || { [ -d "$SRC/files" ] && cp -r "$SRC/files" "$APP/files" || mkdir -p "$APP/files"; }
rm -f "$APP"/data/*.db-shm "$APP"/data/*.db-wal 2>/dev/null || true
# the address the app and the emails use
sed -i "s#^BASE_URL=.*#BASE_URL=https://$DOMAIN#" "$APP/.env"
grep -q '^NODE_ENV=' "$APP/.env" && sed -i 's#^NODE_ENV=.*#NODE_ENV=production#' "$APP/.env" || echo 'NODE_ENV=production' >> "$APP/.env"
grep -q '^PORT=' "$APP/.env" && sed -i 's#^PORT=.*#PORT=8080#' "$APP/.env" || echo 'PORT=8080' >> "$APP/.env"
cd "$APP" && npm ci --omit=dev
chown -R jdo:jdo "$APP"
chmod 600 "$APP/.env"

echo "== service"
cat > /etc/systemd/system/jdo.service <<EOF
[Unit]
Description=Jdo X Abu Qht server
After=network-online.target
Wants=network-online.target

[Service]
User=jdo
WorkingDirectory=$APP
ExecStart=/usr/bin/node src/server.js
Restart=always
RestartSec=3
Environment=NODE_ENV=production

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable --now jdo
systemctl restart jdo

echo "== https"
cat > /etc/caddy/Caddyfile <<EOF
$DOMAIN {
  encode gzip
  request_body {
    max_size 100MB
  }
  reverse_proxy 127.0.0.1:8080
}
EOF
systemctl reload caddy || systemctl restart caddy

echo "== firewall"
if [ -f /etc/iptables/rules.v4 ] && grep -q 'REJECT' /etc/iptables/rules.v4; then
  # Oracle Cloud images: their own iptables rules reject everything but SSH, and ufw must stay off there
  for p in 443 80; do
    iptables -C INPUT -p tcp --dport $p -m state --state NEW -j ACCEPT 2>/dev/null || iptables -I INPUT 5 -p tcp --dport $p -m state --state NEW -j ACCEPT
  done
  command -v netfilter-persistent >/dev/null || apt-get install -y iptables-persistent
  netfilter-persistent save
  echo "Oracle Cloud: also open ports 80 and 443 in the VCN Security List (Ingress, source 0.0.0.0/0)."
else
  apt-get install -y ufw
  ufw allow OpenSSH
  ufw allow 80/tcp
  ufw allow 443/tcp
  ufw --force enable
fi

sleep 3
systemctl --no-pager --lines=15 status jdo || true
echo
echo "Done. Open https://$DOMAIN  (the certificate can take a minute the first time)."
echo "Logs: journalctl -u jdo -f      Restart: systemctl restart jdo"
