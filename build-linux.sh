#!/bin/bash
# build-linux.sh — cross-compile Squid for all Linux targets
# Run this on an Intel (x86-64) Linux box.
#
# Outputs (in ./dist/):
#   squid-sslbump-for-webos-linux-amd64.tar.gz
#   squid-sslbump-for-webos-linux-arm64.tar.gz
#   squid-sslbump-for-webos-linux-armv7.tar.gz
#
# Each tarball contains: squid binary, cert-gen binary, config template,
# startup wrapper, systemd unit, and an install.sh.
#
# NOTE: Building Squid from source takes ~20-40 minutes per target
# on typical hardware. arm64/armv7 take longer due to cross-compilation.

set -e

# ---------------------------------------------------------------
# Versions — update these when upgrading
# Verify checksums at:
#   https://www.openssl.org/source/  (OpenSSL)
#   https://github.com/squid-cache/squid/releases  (Squid)
# ---------------------------------------------------------------
SQUID_VERSION="6.14"
SQUID_SHA256="fe061926dff1563eeed963f6f15a73b120afa31e45d151a0a8a7b04bf0781d33"
OPENSSL_VERSION="1.1.1w"
OPENSSL_SHA256="cf3098950cb4d853ad95c0841f1f9c6d3dc102dccfcacd521d93925208b76ac8"

# squid-cache.org no longer hosts tarballs; releases are on GitHub
SQUID_TAG="SQUID_$(echo "$SQUID_VERSION" | tr '.' '_')"
SQUID_URL="https://github.com/squid-cache/squid/releases/download/${SQUID_TAG}/squid-${SQUID_VERSION}.tar.gz"
OPENSSL_URL="https://www.openssl.org/source/openssl-${OPENSSL_VERSION}.tar.gz"

INSTALL_PREFIX="/usr/local/squid"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_DIR="$SCRIPT_DIR/build"
DIST_DIR="$SCRIPT_DIR/dist"

# ---------------------------------------------------------------
# Target matrix
# ---------------------------------------------------------------
TARGETS=(amd64 arm64 armv7)

declare -A OPENSSL_TARGET=(
    [amd64]="linux-x86_64"
    [arm64]="linux-aarch64"
    [armv7]="linux-armv4"
)
declare -A HOST_TRIPLE=(
    [amd64]=""
    [arm64]="aarch64-linux-gnu"
    [armv7]="arm-linux-gnueabihf"
)
declare -A CROSS_PREFIX=(
    [amd64]=""
    [arm64]="aarch64-linux-gnu-"
    [armv7]="arm-linux-gnueabihf-"
)

# ---------------------------------------------------------------

log() { echo "" && echo "==> $*"; }

install_deps() {
    local pkgs=(
        build-essential wget curl perl
        gcc-aarch64-linux-gnu g++-aarch64-linux-gnu binutils-aarch64-linux-gnu
        gcc-arm-linux-gnueabihf g++-arm-linux-gnueabihf binutils-arm-linux-gnueabihf
        qemu-user-static binfmt-support
    )
    local missing=()
    for pkg in "${pkgs[@]}"; do
        dpkg -s "$pkg" &>/dev/null || missing+=("$pkg")
    done
    if [ ${#missing[@]} -eq 0 ]; then
        echo "All build dependencies already installed."
        return
    fi
    log "Installing build dependencies: ${missing[*]}"
    sudo apt-get update -q
    sudo apt-get install -y -q "${missing[@]}"
}

download_sources() {
    local src_dir="$BUILD_DIR/src"
    mkdir -p "$src_dir"

    log "Downloading OpenSSL $OPENSSL_VERSION..."
    local openssl_archive="$src_dir/openssl-${OPENSSL_VERSION}.tar.gz"
    if [ ! -f "$openssl_archive" ]; then
        wget -q -O "$openssl_archive" "$OPENSSL_URL"
    fi
    echo "$OPENSSL_SHA256  $openssl_archive" | sha256sum -c
    echo "OpenSSL checksum OK."

    log "Downloading Squid $SQUID_VERSION..."
    local squid_archive="$src_dir/squid-${SQUID_VERSION}.tar.gz"
    if [ ! -f "$squid_archive" ]; then
        wget -q -O "$squid_archive" "$SQUID_URL"
    fi
    echo "$SQUID_SHA256  $squid_archive" | sha256sum -c
    echo "Squid checksum OK."
}

build_openssl() {
    local target=$1
    local install_dir="$BUILD_DIR/openssl-$target"

    if [ -f "$install_dir/lib/libssl.a" ]; then
        echo "OpenSSL/$target already built, skipping."
        return
    fi

    log "Building OpenSSL $OPENSSL_VERSION for $target..."
    local build_dir="$BUILD_DIR/openssl-${OPENSSL_VERSION}-${target}"
    rm -rf "$build_dir"
    tar xf "$BUILD_DIR/src/openssl-${OPENSSL_VERSION}.tar.gz" -C "$BUILD_DIR"
    mv "$BUILD_DIR/openssl-${OPENSSL_VERSION}" "$build_dir"

    pushd "$build_dir" > /dev/null
    local cross="${CROSS_PREFIX[$target]}"
    if [ -n "$cross" ]; then
        ./Configure "${OPENSSL_TARGET[$target]}" \
            --prefix="$install_dir" \
            --cross-compile-prefix="$cross" \
            no-shared no-tests
    else
        ./config \
            --prefix="$install_dir" \
            no-shared no-tests
    fi
    make -j"$(nproc)" 2>&1
    make install_sw 2>&1
    popd > /dev/null
    rm -rf "$build_dir"
}

build_squid() {
    local target=$1
    local install_dir="$BUILD_DIR/squid-$target"
    local openssl_dir="$BUILD_DIR/openssl-$target"
    local cross="${CROSS_PREFIX[$target]}"
    local host="${HOST_TRIPLE[$target]}"

    if [ -f "$install_dir/sbin/squid" ]; then
        echo "Squid/$target already built, skipping."
        return
    fi

    log "Building Squid $SQUID_VERSION for $target..."
    local build_dir="$BUILD_DIR/squid-${SQUID_VERSION}-${target}"
    rm -rf "$build_dir"
    tar xf "$BUILD_DIR/src/squid-${SQUID_VERSION}.tar.gz" -C "$BUILD_DIR"
    mv "$BUILD_DIR/squid-${SQUID_VERSION}" "$build_dir"

    pushd "$build_dir" > /dev/null

    local configure_args=(
        "--prefix=/usr/local/squid"
        "--with-openssl=$openssl_dir"
        "--enable-ssl-crtd"
        "--with-large-files"
        "--enable-icap-client"
        "--enable-basic-auth-helpers=NCSA"
        "--disable-esi"
        "--disable-snmp"
        "--without-gss"
        "--without-kerberos"
        "--without-ldap"
        "--without-netfilter-conntrack"
        "--with-default-user=squid"
    )

    export PKG_CONFIG_PATH="$openssl_dir/lib/pkgconfig"
    export CPPFLAGS="-I$openssl_dir/include"
    export LDFLAGS="-L$openssl_dir/lib"

    if [ -n "$host" ]; then
        configure_args+=("--host=$host")
        # Prevent Squid's configure from running getconf on the build host to
        # determine large-file CFLAGS — on x86_64 that adds -m64, which the
        # cross-compiler rejects.
        configure_args+=("--with-build-environment=default")
        export CC="${cross}gcc"
        export CXX="${cross}g++"
        export AR="${cross}ar"
        export RANLIB="${cross}ranlib"
        export STRIP="${cross}strip"
        # Prevent autoconf from injecting host-arch flags (e.g. -m64) which
        # the cross-compiler does not accept.
        export CFLAGS="-g -O2"
        export CXXFLAGS="-g -O2"
        # Provide cache values for configure tests that require execution
        # (can't run cross-compiled binaries on the build host)
        cat > cross-cache.conf <<EOF
ac_cv_func_setresuid=yes
ac_cv_func_setresgid=yes
squid_cv_gnu_atomics=yes
ac_cv_c_bigendian=no
EOF
        ./configure "${configure_args[@]}" --cache-file=cross-cache.conf
    else
        ./configure "${configure_args[@]}"
    fi

    make -j"$(nproc)" 2>&1
    make install DESTDIR="$install_dir" 2>&1

    # Strip to reduce binary size
    local strip_cmd="${cross}strip"
    "$strip_cmd" "$install_dir/usr/local/squid/sbin/squid" 2>/dev/null || true
    find "$install_dir/usr/local/squid/libexec" -type f -executable \
        -exec "$strip_cmd" {} \; 2>/dev/null || true

    popd > /dev/null
    rm -rf "$build_dir"

    unset CC CXX AR RANLIB STRIP PKG_CONFIG_PATH CPPFLAGS LDFLAGS CFLAGS CXXFLAGS
}

package_target() {
    local target=$1
    local squid_dir="$BUILD_DIR/squid-$target"
    local pkg_name="squid-sslbump-for-webos-linux-$target"
    local stage_dir="$BUILD_DIR/stage-$target/$pkg_name"

    log "Packaging $target..."
    rm -rf "$BUILD_DIR/stage-$target"
    mkdir -p "$stage_dir"

    # DESTDIR install puts files under $squid_dir/usr/local/squid/ — copy the
    # full tree so mime.conf, error pages, and all runtime data are included.
    local squid_staged="$squid_dir/usr/local/squid"
    cp -r "$squid_staged/." "$stage_dir/squid"

    # Packaging assets (install scripts, config, service unit live alongside squid/)
    cp "$SCRIPT_DIR/packaging/squid.conf.template" "$stage_dir/"
    cp "$SCRIPT_DIR/packaging/squid-init.sh" "$stage_dir/"
    cp "$SCRIPT_DIR/packaging/setup-server.py" "$stage_dir/"
    cp "$SCRIPT_DIR/packaging/archive-server.py" "$stage_dir/"
    cp "$SCRIPT_DIR/packaging/squid-sslbump.service" "$stage_dir/"
    cp "$SCRIPT_DIR/packaging/install-linux.sh" "$stage_dir/install.sh"
    cp "$SCRIPT_DIR/packaging/uninstall-linux.sh" "$stage_dir/uninstall.sh"
    chmod +x "$stage_dir/squid-init.sh" "$stage_dir/install.sh" "$stage_dir/uninstall.sh"

    # Create tarball
    mkdir -p "$DIST_DIR"
    tar czf "$DIST_DIR/${pkg_name}.tar.gz" \
        -C "$BUILD_DIR/stage-$target" "$pkg_name"

    rm -rf "$BUILD_DIR/stage-$target"
    echo "Created: $DIST_DIR/${pkg_name}.tar.gz"
}

main() {
    echo ""
    echo "squid-sslbump-for-webos — Linux build"
    echo "Squid $SQUID_VERSION + OpenSSL $OPENSSL_VERSION"
    echo "Targets: ${TARGETS[*]}"
    echo ""

    install_deps
    mkdir -p "$BUILD_DIR"
    download_sources

    for target in "${TARGETS[@]}"; do
        echo ""
        echo "----------------------------------------"
        echo " Target: $target"
        echo "----------------------------------------"
        build_openssl "$target"
        build_squid "$target"
        package_target "$target"
    done

    echo ""
    echo "========================================"
    echo " Build complete"
    echo "========================================"
    ls -lh "$DIST_DIR/"
}

main "$@"
