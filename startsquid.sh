#!/bin/bash

SQUID_USER=squid
SQUID_DIR=/usr/local/squid

killall squid
sleep 2

# make sure there's a cert
if [ ! -f $SQUID_DIR/ssl/localCert.pem ]; then
    openssl req -new -newkey rsa:1024 -nodes -days 3650 -x509 -keyout $SQUID_DIR/ssl/localCert.pem -out $SQUID_DIR/ssl/localCert.crt\
	    -subj "/C=US/ST=Ohio/L=Cleveland/O=raspberrypi/OU=NetworkSecurity/CN=raspberrypi"
    openssl x509 -in $SQUID_DIR/ssl/localCert.crt -outform DER -out $SQUID_DIR/ssl/localCert.der
fi

exec $SQUID_DIR/sbin/squid -f $SQUID_DIR/etc/squid.conf -NYCd 10
