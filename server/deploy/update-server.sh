#!/usr/bin/env bash
# After changing the server code: upload the server folder again and run
#   sudo bash deploy/update-server.sh
# Copies the new code only; the database, uploaded versions and .env on the VPS stay as they are.
set -euo pipefail
SRC="$(cd "$(dirname "$0")/.." && pwd)"
APP=/opt/jdo-server
cp -r "$SRC/src" "$SRC/public" "$SRC/package.json" "$SRC/package-lock.json" "$APP/"
cd "$APP" && npm ci --omit=dev
chown -R jdo:jdo "$APP"
systemctl restart jdo
sleep 2
systemctl --no-pager --lines=10 status jdo
