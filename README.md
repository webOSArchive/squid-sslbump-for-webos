# squid-sslbump-for-webos

An SSL-bumping proxy that gives retro webOS devices (Palm Pre, HP TouchPad, etc.) access to modern HTTPS websites. The proxy intercepts HTTPS connections and re-signs them with its own certificate, bridging the gap between devices with outdated SSL stacks and the modern web.

> **Note:** This proxy is intentionally permissive — it accepts weak ciphers, skips upstream certificate verification, and allows all clients. It is designed for use on a private home network, not exposed to the internet. Restrict access with your router's firewall.

---

## Installation

### macOS

Download the latest `squid-sslbump-for-webos-macos-universal.pkg` from the [Releases](../../releases) page and double-click to install. The proxy starts automatically and runs as a background service.

### Linux (x86-64, Raspberry Pi)

Download the tarball for your platform from the [Releases](../../releases) page, then:

```bash
tar xzf squid-sslbump-for-webos-linux-<arch>.tar.gz
cd squid-sslbump-for-webos-linux-<arch>
sudo ./install.sh
```

Supported platforms:
- `linux-amd64` — x86-64 desktop/server
- `linux-arm64` — Raspberry Pi 4 and newer
- `linux-armv7` — Raspberry Pi Zero, 2, and 3

### Windows (WSL2)

Use the `linux-amd64` tarball inside WSL2. WSL2 on Windows 11 supports systemd, so the service installs and runs the same way as Linux.

---

## Setup: configure your device

Once installed, open a browser on any computer on your network and go to:

```
http://<proxy-ip>:3129/
```

This page shows your proxy address and port, lets you download the CA certificate, and has step-by-step setup instructions for common webOS devices.

### Proxy settings to enter on your retro device

| Setting | Value |
|---------|-------|
| Proxy host | your computer's IP address |
| Proxy port | `3128` |

### CA certificate

Your device needs to trust the proxy's certificate to avoid SSL errors. Download and install it from the setup page, or fetch it directly:

```
http://<proxy-ip>:3129/cert
```

The certificate is also available on disk at `/usr/local/squid/ssl/localCert.der` after the first service start.

---

## Verifying it works

**1. Check the service is running**

macOS:
```bash
sudo launchctl list | grep squid
```
A PID (not `-`) next to `com.squid-sslbump-for-webos` means it's running.

Linux:
```bash
sudo systemctl status squid-sslbump
```

**2. Check the proxy port is listening**
```bash
netstat -an | grep 3128
```
Should show `LISTEN` on port 3128.

**3. Send a test request through the proxy**
```bash
curl -x http://localhost:3128 https://example.com -o /dev/null -w "%{http_code}\n"
```
Should print `200`.

**4. Check the setup page is up**

Open `http://localhost:3129/` in a browser. You should see the setup page with a working cert download link.

**5. Check logs if something looks wrong**

macOS:
```bash
tail -f /usr/local/squid/var/logs/squid-service.log
```

Linux:
```bash
sudo journalctl -u squid-sslbump -f
```

---

## Uninstalling

### macOS
```bash
sudo /usr/local/squid/bin/uninstall.sh
```

### Linux
```bash
sudo ./uninstall.sh
```
(The `uninstall.sh` is included in the same tarball as `install.sh`.)

Both uninstallers will ask whether to remove your configuration and certificates (default: keep them), and whether to remove the `squid` system user.

---

## Notes

- Weak encryption and disabled certificate verification are intentional — required for retro devices with outdated SSL stacks.
- Keep this proxy on your private network. Use your router's firewall to limit which devices can reach port 3128.
- Installed to `/usr/local/squid`. Config file at `/usr/local/squid/etc/squid.conf`.

---

## License

MIT — see [LICENSE](LICENSE)
