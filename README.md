# squid-sslbump-for-webos

An SSL-bumping proxy that gives retro webOS devices (Palm Pre, HP TouchPad, etc.) access to modern HTTPS websites. The proxy intercepts HTTPS connections and re-signs them with its own certificate, bridging the gap between devices with outdated SSL stacks and the modern web.

> **Note:** This proxy is intentionally permissive — it accepts weak ciphers, skips upstream certificate verification, and allows all clients. It is designed for use on a private home network, not exposed to the internet. Restrict access with your router's firewall.

---

## Installation

### macOS

Download the latest `squid-sslbump-for-webos-macos-universal.pkg` from the [Releases](../../releases) page and double-click to install. The proxy starts automatically and runs as a background service. 

Platforms supported are Mojave and up, Intel and Apple Silicon.

### Linux (x86-64, Raspberry Pi)

Download the tarball for your platform from the [Releases](../../releases) page, then:

```bash
tar xzf squid-sslbump-for-webos-linux-<arch>.tar.gz
cd squid-sslbump-for-webos-linux-<arch>
sudo ./install.sh
```

| Platform | Use for |
|----------|---------|
| `linux-amd64` | x86-64 desktop/server |
| `linux-arm64` | Raspberry Pi 4 and 5 (64-bit OS) |
| `linux-armv7` | Raspberry Pi Zero, 2, and 3 (32-bit OS) |

### Windows

Two options: Docker Desktop (simpler) or WSL2 (more control).

#### Option A: Docker Desktop

1. Install [Docker Desktop for Windows](https://www.docker.com/products/docker-desktop/).
2. Copy `docker-compose.yml` from this repo to a folder on your machine.
3. Edit the `PROXY_IP` line to your Windows machine's LAN IP (`ipconfig` to find it).
4. Open PowerShell in that folder and run `docker compose up -d`.
5. Allow the ports through Windows Firewall (elevated PowerShell):
   ```powershell
   New-NetFirewallRule -DisplayName "squid-sslbump proxy" -Direction Inbound -Protocol TCP -LocalPort 3128 -Action Allow -Profile Private
   New-NetFirewallRule -DisplayName "squid-sslbump setup" -Direction Inbound -Protocol TCP -LocalPort 3129 -Action Allow -Profile Private
   ```

The proxy starts automatically on boot as long as Docker Desktop is running.

#### Option B: WSL2

Use the `linux-amd64` tarball inside WSL2. WSL2 on Windows 11 supports systemd, so install works the same as Linux.

**Enable systemd** — add to `/etc/wsl.conf` inside WSL, then `wsl --shutdown` in PowerShell:
```ini
[boot]
systemd=true
```

**Enable mirrored networking** — add to `%USERPROFILE%\.wslconfig` on Windows, then `wsl --shutdown`:
```ini
[wsl2]
networkingMode=mirrored
```
This makes the proxy reachable on your Windows machine's LAN IP. Then install using the Linux steps above and open the firewall ports (see Option A step 5).

---

## Setup: configure your device

Once installed, open `http://<proxy-ip>:3129/` in a browser (or `http://localhost:3129/` on the proxy machine). This page shows your proxy address, lets you download the CA certificate, and has step-by-step setup instructions for webOS devices.

Configure your retro device to use:

| Setting | Value |
|---------|-------|
| Proxy host | your proxy machine's IP |
| Proxy port | `3128` |

The CA certificate must be installed as a **trusted CA** on the device to avoid SSL errors. Follow the device-specific instructions on the setup page — the steps differ between Palm Pre/Pixi and HP TouchPad.

---

## Verifying it works

Check the service is running:

| Platform | Command |
|----------|---------|
| macOS | `sudo launchctl list \| grep squid` |
| Linux | `sudo systemctl status squid-sslbump` |
| Docker | `docker compose ps` |

Test the proxy:
```bash
curl -k -x http://localhost:3128 https://example.com -o /dev/null -w "%{http_code}\n"
```
Should print `200`.

Check logs:

| Platform | Command |
|----------|---------|
| macOS | `tail -f /usr/local/squid/var/logs/squid-service.log` |
| Linux | `sudo journalctl -u squid-sslbump -f` |
| Docker | `docker compose logs -f` |

---

## Uninstalling

**macOS:** `sudo /usr/local/squid/bin/uninstall.sh`

**Linux:** `sudo ./uninstall.sh` (included in the tarball alongside `install.sh`)

Both uninstallers prompt before removing certificates and the `squid` system user.

**Docker:** `docker compose down` (stops the container, preserves volumes). Add `-v` to also delete volumes.

---

## Troubleshooting

### Service won't start

Check for port conflicts on 3128, 3129, 3130:
```bash
sudo ss -tlnp | grep -E '3128|3129|3130'
```
Check logs (see commands in [Verifying it works](#verifying-it-works) above).

**First-start failure:** If cert or SSL database initialization fails, remove the generated files and restart:
```bash
sudo rm -rf /usr/local/squid/ssl /usr/local/squid/var/lib/ssl_db
sudo systemctl restart squid-sslbump   # Linux; or docker compose restart for Docker
```

### Device still shows SSL errors

The certificate must be installed as a **trusted CA**, not a regular certificate. Use the setup page and follow the device-specific instructions.

### Can't reach the setup page

The setup server (port 3129) runs alongside Squid — if Squid failed to start, the setup server exits too. Check logs for Squid errors.

On macOS, System Settings → Network → Firewall may be blocking port 3129.

### WSL2: retro device can't reach the proxy

See the mirrored networking step in [Option B: WSL2](#option-b-wsl2) above.

### Docker: setup page shows wrong proxy IP

The setup page may show the container's internal IP instead of your machine's LAN IP. Set `PROXY_IP` in `docker-compose.yml` to your machine's LAN IP. This is display-only — the proxy itself works regardless.

### Linux: systemd not found after install

WSL1 and some minimal installs don't have systemd. WSL2 does — enable it per [Option B: WSL2](#option-b-wsl2) above.

---

## Building from source

### Docker image

```bash
docker build -t squid-sslbump-for-webos:latest .
```

Multi-arch (amd64 + arm64):
```bash
docker buildx create --use --name multiarch --driver docker-container
docker run --privileged --rm tonistiigi/binfmt --install all
docker buildx build --platform linux/amd64,linux/arm64 \
  -t webosarchive/squid-sslbump-for-webos:latest --push .
```

First build takes 30–60 minutes (Squid compiles from source).

### macOS Installer

Run `build-macos.sh` from Terminal. 

Signing and notarization will require an Apple Developer account.
Copy `set-apple-vars.example` to `set-apple-vars.sh` and update with your Developer credentials.

The installer package is written to `./dist/`.

### Linux tarballs

Run `build-linux.sh` on an x86-64 Linux machine. If Docker is available, the script automatically builds inside `ubuntu:20.04` to pin glibc to 2.31 (Raspberry Pi OS Bullseye compatibility). Without Docker, it builds on the host with a warning if the host glibc is newer than the target.

Output tarballs are written to `./dist/`.

---

## License

MIT — see [LICENSE](LICENSE)
