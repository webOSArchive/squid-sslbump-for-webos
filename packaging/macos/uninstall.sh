#!/bin/bash
# uninstall.sh — remove squid-sslbump-for-webos on macOS
# Must be run as root.
# Also available post-install at: /usr/local/squid/bin/uninstall.sh

set -e

SQUID_DIR=/usr/local/squid
SQUID_USER=squid
PLIST="/Library/LaunchDaemons/com.squid-sslbump-for-webos.plist"
PKG_ID="com.squid-sslbump-for-webos"

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

# Unload and remove launchd service
if launchctl list | grep -q "$PKG_ID" 2>/dev/null; then
    echo "Stopping service..."
    launchctl unload -w "$PLIST" 2>/dev/null || true
fi
if [ -f "$PLIST" ]; then
    rm -f "$PLIST"
    echo "Removed launchd plist."
fi

# Remove installation
if [[ "$REMOVE_DATA" =~ ^[Yy]$ ]]; then
    rm -rf "$SQUID_DIR"
    echo "Removed $SQUID_DIR."
else
    # Remove binaries and service files but keep config, certs, and logs
    rm -f "$SQUID_DIR/sbin/squid"
    rm -f "$SQUID_DIR/libexec/security_file_certgen" "$SQUID_DIR/libexec/ssl_crtd"
    rm -f "$SQUID_DIR/bin/squid-init.sh" "$SQUID_DIR/bin/setup-server.py"
    echo "Removed binaries. Config, certs, and logs preserved at $SQUID_DIR."
fi

# Remove pkg receipt so macOS doesn't think it's still installed
if pkgutil --pkg-info "$PKG_ID" &>/dev/null; then
    pkgutil --forget "$PKG_ID"
    echo "Removed package receipt."
fi

# Remove squid user and group
read -r -p "Remove the '$SQUID_USER' system user? [y/N] " REMOVE_USER
if [[ "$REMOVE_USER" =~ ^[Yy]$ ]]; then
    if id "$SQUID_USER" &>/dev/null; then
        dscl . -delete /Users/squid 2>/dev/null || true
        dscl . -delete /Groups/squid 2>/dev/null || true
        echo "Removed user '$SQUID_USER'."
    fi
fi

echo ""
echo "Uninstall complete."
