#!/bin/bash
# install-linux.sh — end-user installer for squid-sslbump-for-webos
# Installs the pre-built Squid binary, config, and systemd service.
# Must be run as root.

set -e

SQUID_DIR=/usr/local/squid
SQUID_USER=squid
SERVICE_NAME=squid-sslbump
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ "$(id -u)" -ne 0 ]; then
    echo "ERROR: This script must be run as root (sudo ./install.sh)" >&2
    exit 1
fi

echo ""
echo "squid-sslbump-for-webos installer"
echo "----------------------------------"

# Create squid system user if not present
if ! id "$SQUID_USER" &>/dev/null; then
    echo "Creating system user '$SQUID_USER'..."
    useradd --system --no-create-home --shell /usr/sbin/nologin "$SQUID_USER"
fi

# Install the full Squid tree (includes mime.conf, error pages, all runtime data)
echo "Installing files to $SQUID_DIR..."
cp -r "$SCRIPT_DIR/squid/." "$SQUID_DIR/"

# Install startup wrapper and setup server
cp "$SCRIPT_DIR/squid-init.sh" "$SQUID_DIR/bin/squid-init.sh"
cp "$SCRIPT_DIR/setup-server.py" "$SQUID_DIR/bin/setup-server.py"
chmod +x "$SQUID_DIR/bin/squid-init.sh" "$SQUID_DIR/bin/setup-server.py"

# Install config (don't overwrite an existing one)
if [ ! -f "$SQUID_DIR/etc/squid.conf" ]; then
    echo "Installing default config..."
    cp "$SCRIPT_DIR/squid.conf.template" "$SQUID_DIR/etc/squid.conf"
else
    echo "Existing config found at $SQUID_DIR/etc/squid.conf — leaving it in place."
    echo "New default config saved as $SQUID_DIR/etc/squid.conf.new for reference."
    cp "$SCRIPT_DIR/squid.conf.template" "$SQUID_DIR/etc/squid.conf.new"
fi

# Create mutable directories and set ownership
mkdir -p "$SQUID_DIR/ssl" "$SQUID_DIR/var/lib" "$SQUID_DIR/var/cache" "$SQUID_DIR/var/logs"
chown -R root:root "$SQUID_DIR"
chown -R "$SQUID_USER:$SQUID_USER" "$SQUID_DIR/var" "$SQUID_DIR/ssl"

# Add squid sbin to system PATH
echo "export PATH=\$PATH:$SQUID_DIR/sbin" > /etc/profile.d/squid-sslbump.sh
chmod +x /etc/profile.d/squid-sslbump.sh

# Install and enable systemd service
echo "Installing systemd service..."
cp "$SCRIPT_DIR/squid-sslbump.service" "/etc/systemd/system/${SERVICE_NAME}.service"
systemctl daemon-reload
systemctl enable "$SERVICE_NAME"
systemctl start "$SERVICE_NAME"

echo ""
echo "Done. Service status:"
systemctl status "$SERVICE_NAME" --no-pager || true
echo ""
echo "Proxy running on port 3128."
echo "Setup page: http://$(hostname -I | awk '{print $1}'):3129/"
