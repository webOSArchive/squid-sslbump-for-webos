# squid-sslbump-for-webos

An SSL-bumping proxy that gives retro webOS devices (Palm Pre, HP TouchPad, etc.) access to modern HTTPS websites. The proxy intercepts HTTPS connections and re-signs them with its own certificate, bridging the gap between devices with outdated SSL stacks and the modern web.

> **Note:** This proxy is intentionally permissive — it accepts weak ciphers, skips upstream certificate verification, and allows all clients. It is designed for use on a private home network, not exposed to the internet. Restrict access with your router's firewall.

---

## Installation

### macOS

Download the latest `squid-sslbump-for-webos-macos-universal.pkg` from the [Releases](../../releases) page and double-click to install. The proxy starts automatically and runs as a background service.

Supported platforms are Mojave and up, on both Intel and Apple Silicon.

### Linux (x86-64, Raspberry Pi)

Download the tarball for your platform from the [Releases](../../releases) page, then:

```bash
tar xzf squid-sslbump-for-webos-linux-<arch>.tar.gz
cd squid-sslbump-for-webos-linux-<arch>
sudo ./install.sh
```

Supported platforms:
- `linux-amd64` — x86-64 desktop/server
- `linux-arm64` — Raspberry Pi 4 and 5 (64-bit OS)
- `linux-armv7` — Raspberry Pi Zero, 2, and 3 (32-bit OS only)

> **Raspberry Pi 4/5:** Use `linux-arm64`. The `armv7` build will not run on a 64-bit OS — you'll get a startup error about a missing file even though the binary is present.

### Windows (WSL2)

Use the `linux-amd64` tarball inside WSL2. WSL2 on Windows 11 supports systemd, so the service installs and runs the same way as Linux.

---

## Setup: configure your device

Once installed, open the setup page in a browser:

On the computer you installed on:

```
http://localhost:3129/
```

Or on any other computer on your network, go to:

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

## Troubleshooting

### Device still shows SSL errors after installing the certificate

The certificate must be installed as a **trusted CA**, not just a regular certificate. On webOS devices, use the setup page (`http://<proxy-ip>:3129/`) and follow the device-specific instructions — the steps differ between Palm Pre/Pixi and HP TouchPad.

If the setup page shows the cert download but the device won't accept it, try fetching the `.der` file directly:
```
http://<proxy-ip>:3129/cert
```

### Device can connect to the proxy but websites fail

Check that the device has the CA certificate installed and trusted. Then test the proxy itself from your computer:
```bash
curl -x http://localhost:3128 https://example.com -o /dev/null -w "%{http_code}\n"
```
If this doesn't return `200`, check the Squid logs (see below).

### Can't reach the setup page (`http://<proxy-ip>:3129/`)

The setup server (Python, port 3129) runs as a background process alongside Squid. Check the service logs — if Squid itself failed to start, the setup server may have also exited.

On macOS, the firewall may block incoming connections on port 3129. Go to **System Settings → Network → Firewall** and add an exception, or temporarily disable the firewall to test.

### Service won't start

**Check for port conflicts.** The proxy uses ports 3128, 3129, and 3130. If any are in use:
```bash
sudo ss -tlnp | grep -E '3128|3129|3130'
```

**Check logs:**

macOS:
```bash
tail -100 /usr/local/squid/var/logs/squid-service.log
```

Linux:
```bash
sudo journalctl -u squid-sslbump -n 100
```

**First-start SSL database error.** On first start, `squid-init.sh` generates a CA certificate and initializes the SSL database. If this fails (e.g. due to permissions), delete the generated files and restart:
```bash
sudo rm -rf /usr/local/squid/ssl /usr/local/squid/var/lib/ssl_db
sudo systemctl restart squid-sslbump   # Linux
```

### Linux: service not found after install

The installer requires systemd. On minimal installs (some containers, WSL1), systemd may not be present. WSL2 on Windows 11 does support systemd — enable it in `/etc/wsl.conf`:
```ini
[boot]
systemd=true
```
Then restart WSL (`wsl --shutdown` in PowerShell, then reopen).

---

## Building from source (Linux)

Run `build-linux.sh` on an x86-64 Linux machine to produce tarballs for all three platforms.

### Recommended: build with Docker

If Docker is installed, the script automatically re-execs itself inside an `ubuntu:20.04` container. This pins glibc to 2.31, which matches Raspberry Pi OS Bullseye — ensuring the binaries run on all Pi OS versions from Bullseye onward.

```bash
bash build-linux.sh
```

Docker must be runnable by the current user (i.e. the user is in the `docker` group, or you prefix with `sudo`).

### Without Docker

If Docker is not available, the script builds on the host. The resulting binaries require the host's glibc version, which may be too new for older target systems. A warning is printed when this happens.

Host build dependencies (installed automatically if missing):

```bash
sudo apt-get install -y \
    build-essential wget curl perl \
    gcc-aarch64-linux-gnu g++-aarch64-linux-gnu binutils-aarch64-linux-gnu \
    gcc-arm-linux-gnueabihf g++-arm-linux-gnueabihf binutils-arm-linux-gnueabihf \
    qemu-user-static binfmt-support
```

`qemu-user-static` and `binfmt-support` are required to run the arm64/armv7 cross-compiled build tools on the x86-64 host during compilation (via QEMU binfmt_misc).

### Output

Tarballs are written to `./dist/`. Each contains the Squid binary, helpers, config template, startup wrapper, systemd unit, and install/uninstall scripts.

Building takes roughly 20–40 minutes on typical hardware (arm64/armv7 are slower due to cross-compilation and QEMU emulation of build tools).

---

## Notes

- Weak encryption and disabled certificate verification are intentional — required for retro devices with outdated SSL stacks.
- Keep this proxy on your private network. Use your router's firewall to limit which devices can reach port 3128.
- Installed to `/usr/local/squid`. Config file at `/usr/local/squid/etc/squid.conf`.

---

## License

MIT — see [LICENSE](LICENSE)
