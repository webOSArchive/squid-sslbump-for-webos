# Docker packaging plan — squid-sslbump-for-webos

## Goal

Package the proxy as a Docker image so Windows (and Linux) users can run it via
Docker Desktop without any command-line Squid setup. The image targets hobbyists
who are comfortable with Docker but not with system administration.

## User-facing experience (target)

```
docker compose up -d
```

Then open `http://<host-ip>:3129/` in a browser for the cert download and device
setup instructions. That's it. Ports 3128/3129/3130 are exposed to the host.

## Ports to expose

| Port | Service |
|------|---------|
| 3128 | Squid proxy (SSL bump) — retro devices point here |
| 3129 | Setup web page (cert download, add-on manager) |
| 3130 | Archive server (internal; exposed for completeness) |

## Persistent volumes needed

The following paths must survive container restarts. Without volumes, the CA cert
regenerates on every start and users must re-install it on their devices.

| Volume | Path in container | Contents |
|--------|-------------------|----------|
| `squid-ssl` | `/usr/local/squid/ssl/` | Generated CA cert (pem, crt, der) |
| `squid-ssldb` | `/usr/local/squid/var/lib/ssl_db/` | Squid SSL cert cache |
| `squid-archive` | `/usr/local/squid/var/archive/` | Installed add-on content |
| `squid-logs` | `/usr/local/squid/var/logs/` | Optional — useful for debugging |

## Files to create

```
Dockerfile
docker-compose.yml
.dockerignore
```

These live at the repo root alongside `build-macos.sh` and `build-linux.sh`.

---

## Dockerfile design

Use a **two-stage build**:

- **Stage 1 (`builder`)** — `ubuntu:20.04` (same image `build-linux.sh` uses
  internally). Builds OpenSSL 1.1.1w (static) and Squid 6.14 for amd64.
  Versions and checksums are the same as in `build-linux.sh` — keep them in sync
  when upgrading.

- **Stage 2 (`runtime`)** — `debian:bullseye-slim` (glibc 2.31, same ABI
  target as the existing Linux build). Copies the compiled install tree from
  stage 1, adds the `squid` system user, installs `openssl` and `python3`
  (system packages), copies the `packaging/` scripts, writes `squid.conf` from
  the template, and sets `squid-init.sh` as the entrypoint.

Why two stages: the builder image pulls in ~1 GB of build tooling that has no
place in the distributed image. The runtime image should be small (~150 MB).

### Runtime image setup checklist

Inside the Dockerfile's runtime stage:

1. `apt-get install -y openssl python3` — `squid-init.sh` calls the system
   `openssl` binary directly for cert generation; the Python servers need
   `python3`.
2. `useradd -r -s /bin/false squid` — Squid drops privileges to this user.
   The `chown` in `squid-init.sh` will fail silently (has `|| true`) if the
   user doesn't exist, but Squid itself will refuse to start.
3. Copy install tree to `/usr/local/squid/` — mirror the layout from
   `install-linux.sh`:
   ```
   /usr/local/squid/sbin/squid
   /usr/local/squid/libexec/security_file_certgen  (and other helpers)
   /usr/local/squid/bin/squid-init.sh
   /usr/local/squid/bin/setup-server.py
   /usr/local/squid/bin/archive-server.py
   /usr/local/squid/etc/squid.conf          ← copy from squid.conf.template
   /usr/local/squid/etc/mime.conf           ← from Squid build output
   /usr/local/squid/share/errors/           ← from Squid build output
   ```
4. Pre-create writable dirs with correct ownership:
   ```
   mkdir -p /usr/local/squid/var/{logs,cache,lib,archive}
   chown -R squid:squid /usr/local/squid/var /usr/local/squid/ssl
   ```
   The ssl/ dir doesn't exist yet (created by squid-init.sh at first start),
   but pre-creating it owned by squid avoids a race.
5. `EXPOSE 3128 3129 3130`
6. `VOLUME` declarations for the four persistent paths (belt-and-suspenders;
   docker-compose.yml also declares them).
7. `ENTRYPOINT ["/usr/local/squid/bin/squid-init.sh"]`

### squid-init.sh in a container

The script is already container-friendly:
- Squid runs with `-N` (foreground) so the container stays alive.
- Python servers are backgrounded with an EXIT trap to clean up when Squid stops.
- Cert and ssl_db generation is idempotent — skipped if files already exist,
  which is the normal case after first start.

No changes to `squid-init.sh` should be needed.

### squid.conf in a container

`squid.conf.template` is copied as `squid.conf` at image build time (no
installer runs at runtime). This is correct — the template has no runtime
substitution variables. It's already the final config.

One potential issue: `squid.conf` sets `cache_effective_user squid` and
`cache_effective_group squid`. Squid won't start if those don't match the
user created in step 2 above. Verify this matches.

---

## docker-compose.yml design

```yaml
services:
  squid:
    image: webosarchive/squid-sslbump-for-webos:latest
    restart: unless-stopped
    ports:
      - "3128:3128"
      - "3129:3129"
      - "3130:3130"
    volumes:
      - squid-ssl:/usr/local/squid/ssl
      - squid-ssldb:/usr/local/squid/var/lib/ssl_db
      - squid-archive:/usr/local/squid/var/archive
      - squid-logs:/usr/local/squid/var/logs

volumes:
  squid-ssl:
  squid-ssldb:
  squid-archive:
  squid-logs:
```

`restart: unless-stopped` means the proxy survives reboots automatically —
important for always-on home use.

---

## Multi-arch publishing

The existing Linux build targets amd64, arm64, and armv7. The Docker image
should match. Use `docker buildx` with `--platform linux/amd64,linux/arm64`
(armv7/arm32 can be added later if there's demand — it complicates the build).

Build and push command:
```bash
docker buildx build \
  --platform linux/amd64,linux/arm64 \
  --tag webosarchive/squid-sslbump-for-webos:latest \
  --push \
  .
```

This requires a buildx builder with multi-arch support. On the Linux build
machine, set one up with:
```bash
docker buildx create --use --name multiarch --driver docker-container
docker run --privileged --rm tonistiigi/binfmt --install all
```

The second command registers QEMU binfmt handlers so the Linux machine can
build arm64 images (same mechanism `build-linux.sh` already uses for
cross-compilation).

---

## Build machine requirements

- Intel (amd64) Linux machine — same requirement as `build-linux.sh`
- Docker with buildx plugin
- Internet access (downloads Squid and OpenSSL source; same URLs as
  `build-linux.sh`)

The build will take ~30-60 minutes on first run (Squid compiles from source
for each arch). Subsequent builds are fast if the Docker layer cache is warm.

---

## Task list

- [ ] Write `Dockerfile` (two-stage: builder + runtime)
- [ ] Write `docker-compose.yml`
- [ ] Write `.dockerignore` (exclude `build/`, `dist/`, `*.pkg`, macOS scripts)
- [ ] Test: `docker build -t squid-sslbump-test .` on Linux machine (amd64 only first)
- [ ] Test: `docker compose up`, verify all three ports, verify cert persists across restart
- [ ] Test: point a webOS device at the container and confirm SSL-bump works
- [ ] Set up buildx for multi-arch and do a `--load` test for arm64
- [ ] Create Docker Hub repo `webosarchive/squid-sslbump-for-webos`
- [ ] Push multi-arch image with `--push`
- [ ] Update README with Docker install instructions

---

## Notes / gotchas

- **openssl binary**: `squid-init.sh` calls `/usr/bin/openssl` (or wherever
  the system openssl lands). The Squid build uses its own statically-linked
  OpenSSL 1.1.1w, but the cert generation at startup uses the *system* openssl.
  `debian:bullseye-slim` ships OpenSSL 1.1.1 — version compatibility is fine.

- **squid.conf cache_dir**: the default config has `cache deny all` so no disk
  cache is used. No `cache_dir` volume is needed.

- **setup-server.py proxy IP detection**: the setup page tells users what IP
  to configure on their device. Inside Docker, `setup-server.py` will see the
  container's internal IP, not the host IP. Check whether it does interface
  enumeration and whether that needs adjustment for the container network
  namespace. If it does, a fix may be needed (e.g. prefer the default route
  interface, or read from an env var).

- **Archive server add-on install**: the add-on installer in `setup-server.py`
  downloads a ZIP from GitHub and extracts to `var/archive/`. With the volume
  mounted this will persist correctly. No changes needed.
