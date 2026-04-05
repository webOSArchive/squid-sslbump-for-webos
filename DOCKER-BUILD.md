# Building and publishing the Docker image

## Prerequisites

- x86-64 Linux machine with Docker installed
- Docker Hub account with access to the `webosarchive` org
- `docker buildx` plugin (see below if missing)

### Install buildx (one-time, if missing)

```bash
mkdir -p ~/.docker/cli-plugins
curl -Lo ~/.docker/cli-plugins/docker-buildx \
  https://github.com/docker/buildx/releases/latest/download/buildx-linux-amd64
chmod +x ~/.docker/cli-plugins/docker-buildx
docker buildx version   # verify
```

### Set up the multi-arch builder (one-time per machine)

```bash
docker buildx create --use --name multiarch --driver docker-container
docker run --privileged --rm tonistiigi/binfmt --install all
```

The second command registers QEMU handlers so the machine can build arm64 images via emulation. You can verify with `docker buildx ls` — the `multiarch` builder should show `linux/amd64, linux/arm64` under supported platforms.

---

## Building and pushing

From the repo root:

```bash
docker login
docker buildx build \
  --platform linux/amd64,linux/arm64 \
  -t webosarchive/squid-sslbump-for-webos:latest \
  --push \
  .
```

The first build takes 30–60 minutes — Squid and OpenSSL compile from source for each arch. Subsequent builds are much faster with a warm layer cache.

`--push` sends the multi-arch manifest directly to Docker Hub. Nothing is stored locally.

### Verify the result

```bash
docker buildx imagetools inspect webosarchive/squid-sslbump-for-webos:latest
```

You should see manifests for both `linux/amd64` and `linux/arm64`.

---

## Testing locally before pushing

To test a single arch without pushing:

```bash
docker build -t squid-sslbump-test .
docker compose up -d   # uses the local image if you edit docker-compose.yml to match
```

Or use buildx with `--load` (single platform only):

```bash
docker buildx build --platform linux/amd64 --load -t squid-sslbump-test .
```

---

## Updating versions

Squid and OpenSSL versions are set as `ARG` defaults at the top of `Dockerfile`. They must be kept in sync with the versions in `build-linux.sh`:

```
SQUID_VERSION, SQUID_SHA256, SQUID_TAG
OPENSSL_VERSION, OPENSSL_SHA256
```

Update all four files (`Dockerfile`, `build-linux.sh`) when upgrading either dependency.
