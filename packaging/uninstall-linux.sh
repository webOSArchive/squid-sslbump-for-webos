#!/bin/bash
# uninstall-linux.sh — remove squid-sslbump-for-webos
# Must be run as root.

set -e

SQUID_DIR=/usr/local/squid
SQUID_USER=squid
SERVICE_NAME=squid-sslbump

if [ "$(id -u)" -ne 0 ]; then
    echo "ERROR: This script must be run as root (sudo ./uninstall.sh)" >&2
    exit 1
fi

echo ""
echo "squid-sslbump-for-webos uninstaller"
echo "------------------------------------"
echo ""

# Ask about config and certs before doing anything destructive
read -r -p "Remove config and certificates too? Generated certs cannot be recovered. [y/N] " REMOVE_DATA
echo ""

# Stop and disable service
if systemctl is-active --quiet "$SERVICE_NAME" 2>/dev/null; then
    echo "Stopping service..."
    systemctl stop "$SERVICE_NAME"
fi
if systemctl is-enabled --quiet "$SERVICE_NAME" 2>/dev/null; then
    echo "Disabling service..."
    systemctl disable "$SERVICE_NAME"
fi

# Remove systemd unit
if [ -f "/etc/systemd/system/${SERVICE_NAME}.service" ]; then
    rm -f "/etc/systemd/system/${SERVICE_NAME}.service"
    systemctl daemon-reload
    echo "Removed systemd unit."
fi

# Remove PATH profile
rm -f /etc/profile.d/squid-sslbump.sh
echo "Removed PATH profile."

# Remove installation
if [[ "$REMOVE_DATA" =~ ^[Yy]$ ]]; then
    rm -rf "$SQUID_DIR"
    echo "Removed $SQUID_DIR."
else
    # Remove binaries and service files but keep config, certs, and logs
    rm -f "$SQUID_DIR/sbin/squid"
    rm -f "$SQUID_DIR/libexec/security_file_certgen" "$SQUID_DIR/libexec/ssl_crtd"
    rm -f "$SQUID_DIR/bin/squid-init.sh" "$SQUID_DIR/bin/setup-server.py" "$SQUID_DIR/bin/archive-server.py"
    echo "Removed binaries. Config, certs, and logs preserved at $SQUID_DIR."
fi

# Remove squid user
read -r -p "Remove the '$SQUID_USER' system user? [y/N] " REMOVE_USER
if [[ "$REMOVE_USER" =~ ^[Yy]$ ]]; then
    if id "$SQUID_USER" &>/dev/null; then
        userdel "$SQUID_USER" 2>/dev/null || true
        groupdel "$SQUID_USER" 2>/dev/null || true
        echo "Removed user '$SQUID_USER'."
    fi
fi

echo ""
echo "Uninstall complete."
