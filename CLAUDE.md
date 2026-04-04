# squid-sslbump-for-webos — Claude Context

## What this project is

An SSL-bumping proxy for retro devices (Palm/HP webOS, legacy smart TVs) with outdated SSL stacks. Intentionally permissive — weak crypto, no peer verification, self-signed CA. This is by design; the target devices can't do better.

The proxy intercepts HTTPS, re-signs with a local CA, and forwards. A setup web page (port 3129) handles cert download and device instructions. An archive server (port 3130) serves locally-hosted restored websites (e.g. help.palm.com) via Squid `cache_peer` routing.

**All active development is on the `installable` branch.** `main` only has the original pre-installer files.

## Key files

| File | Purpose |
|------|---------|
| `build-macos.sh` | Builds universal macOS `.pkg` (arm64 + x86_64), notarizes, staples |
| `build-linux.sh` | Builds Linux tarball per arch |
| `packaging/squid.conf.template` | Squid config; installed as `squid.conf` on first install |
| `packaging/squid-init.sh` | Service entrypoint: generates cert, starts setup+archive servers, runs Squid |
| `packaging/setup-server.py` | HTTP server on port 3129: cert download, device setup instructions, add-on manager |
| `packaging/archive-server.py` | HTTP server on port 3130: serves archived websites by `Host` header |
| `packaging/install-linux.sh` | End-user Linux installer (run as root) |
| `packaging/uninstall-linux.sh` | Linux uninstaller |
| `packaging/macos/postinstall` | macOS pkg postinstall script |

## Architecture

```
retro device → Squid :3128 (SSL bump) → internet
                  ↓ (archived domains)
            archive-server :3130 → /usr/local/squid/var/archive/
```

- **Port 3128** — Squid proxy (SSL bump)
- **Port 3129** — Setup web page (cert download, instructions, add-on manager)
- **Port 3130** — Archive server (local static files, routed from Squid via `cache_peer`)

All three are started by `squid-init.sh`. The setup and archive servers are Python background processes; Squid is the foreground process. An EXIT trap kills the Python servers when Squid stops.

## Squid config notes

- ACLs must be defined **before** they are referenced by directives like `always_direct`
- `always_direct deny archived_domains` must come before `always_direct allow all` or it's ignored
- `cache_peer` routes archived domains to port 3130 via `never_direct allow archived_domains`

## macOS build notes

- Requires Apple Developer ID credentials for signing and notarization
- `scripts/set-apple-vars.sh` sets `CODE_SIGNING_IDENTITY`, `NOTARIZATION_APPLE_ID`, etc.
- Deployment targets: arm64 = macOS 11.0 (Big Sur), x86_64 = macOS 10.14 (Mojave)
- **All** Mach-O binaries must be lipo'd (17 total) and codesigned — not just `squid` and `security_file_certgen`
- Signing happens in `build_pkg` after full payload assembly, scanning all Mach-O files

## Setup server (port 3129) notes

- All JavaScript must be **ES5-compatible** — webOS cannot run ES6 (no arrow functions, no `fetch`, no `const`/`let`)
- Use `XMLHttpRequest` instead of `fetch`; `function()` instead of arrow functions
- Avoid CSS `gap` — use margins instead
- **Do not change heading tags** (`<h2>`) in the device setup sections — user set these intentionally
- Add-on install note should say "Install from a modern browser — not from a retro device"

## Archive server (port 3130) notes

- Keyed by `Host` header via `HOST_MAP` dict
- `help.palm.com` and `downloads.help.palm.com` both map to `help.palm.com` install dir
- Add-on content lives in `/usr/local/squid/var/archive/<hostname>/`
- Install: downloads ZIP from GitHub (~300 MB), extracts to `var/archive/`
- PHP files redirect to GitHub; CGI returns 501; path traversal is blocked

## Install locations

```
/usr/local/squid/
  sbin/squid
  libexec/security_file_certgen  (and other helpers)
  bin/squid-init.sh
  bin/setup-server.py
  bin/archive-server.py
  etc/squid.conf
  ssl/localCert.{pem,crt,der}   (generated on first start)
  var/lib/ssl_db/                (generated on first start)
  var/logs/
  var/cache/
  var/archive/                   (add-on content installed here)
```

## Pending / future work

- Linux build and test (deferred — needs Intel Linux box)
- DNS component (dnsmasq) for additional archived retro sites
- Additional archived website add-ons beyond help.palm.com
- GitHub Actions CI/CD
