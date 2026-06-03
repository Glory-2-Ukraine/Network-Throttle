#!/bin/bash
# =============================================================================
# install.sh — One-command installer for throttle.sh
# Run as root: sudo bash install.sh
# =============================================================================
set -euo pipefail

if [[ $EUID -ne 0 ]]; then
    echo "ERROR: Run as root: sudo bash install.sh"
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "[1/4] Copying throttle.sh to /usr/local/bin/"
cp "$SCRIPT_DIR/throttle.sh" /usr/local/bin/throttle.sh
chmod +x /usr/local/bin/throttle.sh

echo "[2/4] Copying throttle.service to /etc/systemd/system/"
cp "$SCRIPT_DIR/throttle.service" /etc/systemd/system/throttle.service

echo "[3/4] Copying throttle.ini to /etc/ (only if not already present)"
if [[ ! -f /etc/throttle.ini ]]; then
    cp "$SCRIPT_DIR/throttle.ini" /etc/throttle.ini
    echo "      Installed sample throttle.ini — edit /etc/throttle.ini before starting."
else
    echo "      /etc/throttle.ini already exists — not overwritten."
fi

echo "[4/4] Enabling and starting service"
systemctl daemon-reload
systemctl enable throttle.service
systemctl start throttle.service

echo ""
echo "Installation complete."
echo "Check status:  sudo systemctl status throttle"
echo "View logs:     sudo journalctl -t throttle -f"
echo "Edit config:   sudo nano /etc/throttle.ini"
echo "Apply changes: sudo systemctl restart throttle"
