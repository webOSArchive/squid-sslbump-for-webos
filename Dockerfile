# squid-sslbump-for-webos — Dockerfile
#
# Two-stage build:
#   builder  — ubuntu:20.04, compiles OpenSSL (static) + Squid from source
#   runtime  — debian:bullseye-slim, runs the proxy
#
# Versions must be kept in sync with build-linux.sh.
# Build single-arch:  docker build -t squid-sslbump-test .
# Build multi-arch:   docker buildx build --platform linux/amd64,linux/arm64 --push \
#                       -t webosarchive/squid-sslbump-for-webos:latest .

# ---------------------------------------------------------------
# Stage 1: builder
# ---------------------------------------------------------------
FROM ubuntu:20.04 AS builder

ARG DEBIAN_FRONTEND=noninteractive

# Versions — keep in sync with build-linux.sh
ARG SQUID_VERSION=6.14
ARG SQUID_SHA256=fe061926dff1563eeed963f6f15a73b120afa31e45d151a0a8a7b04bf0781d33
ARG OPENSSL_VERSION=1.1.1w
ARG OPENSSL_SHA256=cf3098950cb4d853ad95c0841f1f9c6d3dc102dccfcacd521d93925208b76ac8
# SQUID_TAG format: SQUID_<major>_<minor> — update when SQUID_VERSION changes
ARG SQUID_TAG=SQUID_6_14

RUN apt-get update -q && apt-get install -y -q \
    build-essential wget perl && \
    rm -rf /var/lib/apt/lists/*

# --- OpenSSL ---
RUN cd /tmp && \
    wget -q -O openssl.tar.gz \
        "https://www.openssl.org/source/openssl-${OPENSSL_VERSION}.tar.gz" && \
    echo "${OPENSSL_SHA256}  openssl.tar.gz" | sha256sum -c && \
    tar xf openssl.tar.gz && \
    rm openssl.tar.gz

# no-dso no-engine: eliminates libdl dependency that breaks static linking.
# Neither is needed for SSL bumping (they're for hardware crypto accelerators).
RUN cd /tmp/openssl-${OPENSSL_VERSION} && \
    ./config --prefix=/opt/openssl no-shared no-tests no-dso no-engine && \
    make -j$(nproc) && \
    make install_sw && \
    cd /tmp && rm -rf openssl-${OPENSSL_VERSION}

# --- Squid ---
RUN cd /tmp && \
    wget -q -O squid.tar.gz \
        "https://github.com/squid-cache/squid/releases/download/${SQUID_TAG}/squid-${SQUID_VERSION}.tar.gz" && \
    echo "${SQUID_SHA256}  squid.tar.gz" | sha256sum -c && \
    tar xf squid.tar.gz && \
    rm squid.tar.gz

# SSL_get0_param lives in libssl but Squid's configure checks libcrypto.
# Pre-seeding avoids a compat fallback that tries to access opaque ssl_st (fails on 1.1.1).
# --no-as-needed forces libpthread into every link so static libcrypto.a's pthread
# symbols resolve even in sub-targets that don't include $(LIBS).
RUN cd /tmp/squid-${SQUID_VERSION} && \
    echo "ac_cv_lib_crypto_SSL_get0_param=yes" > native-cache.conf && \
    PKG_CONFIG_PATH=/opt/openssl/lib/pkgconfig \
    CPPFLAGS="-I/opt/openssl/include" \
    LDFLAGS="-L/opt/openssl/lib -Wl,--no-as-needed -lpthread -Wl,--as-needed" \
    ./configure \
        --prefix=/usr/local/squid \
        --with-openssl=/opt/openssl \
        --enable-ssl-crtd \
        --with-large-files \
        --enable-icap-client \
        --disable-auth \
        --disable-esi \
        --disable-snmp \
        --without-gss \
        --without-kerberos \
        --without-ldap \
        --without-netfilter-conntrack \
        --with-default-user=squid \
        --cache-file=native-cache.conf && \
    make -j$(nproc) && \
    make install && \
    strip /usr/local/squid/sbin/squid 2>/dev/null || true && \
    find /usr/local/squid/libexec -type f -executable \
        -exec strip {} \; 2>/dev/null || true && \
    cd /tmp && rm -rf squid-${SQUID_VERSION}

# ---------------------------------------------------------------
# Stage 2: runtime
# ---------------------------------------------------------------
FROM debian:bullseye-slim

ARG DEBIAN_FRONTEND=noninteractive

# openssl: squid-init.sh calls the system openssl binary for cert generation.
# python3: setup-server.py and archive-server.py require it.
RUN apt-get update -q && apt-get install -y -q openssl python3 && \
    rm -rf /var/lib/apt/lists/*

# Squid drops privileges to this user (must match cache_effective_user in squid.conf)
RUN useradd -r -s /bin/false squid

# Copy compiled Squid install tree (sbin, libexec, share/errors, etc/mime.conf, ...)
COPY --from=builder /usr/local/squid /usr/local/squid

# Packaging scripts and config
COPY packaging/squid-init.sh       /usr/local/squid/bin/squid-init.sh
COPY packaging/setup-server.py     /usr/local/squid/bin/setup-server.py
COPY packaging/archive-server.py   /usr/local/squid/bin/archive-server.py
# squid.conf.template has no runtime substitution variables — it is the final config
COPY packaging/squid.conf.template /usr/local/squid/etc/squid.conf

RUN chmod +x \
        /usr/local/squid/bin/squid-init.sh \
        /usr/local/squid/sbin/squid && \
    find /usr/local/squid/libexec -type f -executable -exec chmod +x {} \; && \
    mkdir -p \
        /usr/local/squid/var/logs \
        /usr/local/squid/var/cache \
        /usr/local/squid/var/lib \
        /usr/local/squid/var/archive \
        /usr/local/squid/ssl && \
    chown -R squid:squid /usr/local/squid/var /usr/local/squid/ssl

EXPOSE 3128 3129 3130

VOLUME ["/usr/local/squid/ssl", \
        "/usr/local/squid/var/lib/ssl_db", \
        "/usr/local/squid/var/archive", \
        "/usr/local/squid/var/logs"]

ENTRYPOINT ["/usr/local/squid/bin/squid-init.sh"]
