#!/bin/bash
# squid-init.sh — cert init + startup wrapper
# Called by systemd/launchd as the service entrypoint.

set -e

SQUID_DIR=/usr/local/squid
CERT_KEY="$SQUID_DIR/ssl/localCert.pem"
CERT_CRT="$SQUID_DIR/ssl/localCert.crt"
CERT_DER="$SQUID_DIR/ssl/localCert.der"
SSL_DB="$SQUID_DIR/var/lib/ssl_db"

# Locate the cert generation binary (name changed in Squid 6.x)
if [ -x "$SQUID_DIR/libexec/security_file_certgen" ]; then
    CERTGEN="$SQUID_DIR/libexec/security_file_certgen"
elif [ -x "$SQUID_DIR/libexec/ssl_crtd" ]; then
    CERTGEN="$SQUID_DIR/libexec/ssl_crtd"
else
    echo "ERROR: cert generation binary not found in $SQUID_DIR/libexec/" >&2
    exit 1
fi

# Generate self-signed CA cert if not present
if [ ! -f "$CERT_KEY" ]; then
    echo "Generating self-signed CA certificate..."
    mkdir -p "$SQUID_DIR/ssl"
    openssl req -new -newkey rsa:1024 -days 3650 -nodes -x509 \
        -keyout "$CERT_KEY" \
        -out "$CERT_CRT" \
        -subj "/C=US/ST=State/L=City/O=squid-sslbump-for-webos/OU=Proxy/CN=squid-proxy"
    # Export DER format for installation on retro devices
    openssl x509 -in "$CERT_CRT" -outform DER -out "$CERT_DER"
    echo "CA certificate written to $CERT_CRT"
    echo "DER format (for device installation) written to $CERT_DER"
fi

# Initialize SSL certificate database if not present
if [ ! -d "$SSL_DB" ]; then
    echo "Initializing SSL certificate database..."
    mkdir -p "$SQUID_DIR/var/lib"
    "$CERTGEN" -c -s "$SSL_DB" -M 4MB
fi

# Ensure ownership is correct
chown -R squid:squid "$SQUID_DIR/ssl" "$SQUID_DIR/var" 2>/dev/null || true

# Start setup server (serves cert download + instructions on port 3129)
python3 "$SQUID_DIR/bin/setup-server.py" &
SETUP_PID=$!
trap "kill $SETUP_PID 2>/dev/null" EXIT

# Run Squid (not exec, so the EXIT trap fires when Squid stops)
"$SQUID_DIR/sbin/squid" -N -f "$SQUID_DIR/etc/squid.conf"
