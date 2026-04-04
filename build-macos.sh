#!/bin/bash
# build-macos.sh — build Squid for macOS and package as a signed .pkg
# Run this on your Mac (Apple Silicon or Intel).
#
# Output (in ./dist/):
#   squid-sslbump-for-webos-macos-universal.pkg
#
# Prerequisites:
#   - Xcode Command Line Tools (xcode-select --install)
#   - Developer ID Installer certificate in your keychain
#   - scripts/set-apple-vars.sh (copy from scripts/set-apple-vars.example and fill in)

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_DIR="$SCRIPT_DIR/build"
DIST_DIR="$SCRIPT_DIR/dist"

# ---------------------------------------------------------------
# Load signing credentials from scripts/set-apple-vars.sh
# ---------------------------------------------------------------
APPLE_VARS="$SCRIPT_DIR/scripts/set-apple-vars.sh"
if [ -f "$APPLE_VARS" ]; then
    # shellcheck source=scripts/set-apple-vars.example
    source "$APPLE_VARS"
else
    echo "WARNING: $APPLE_VARS not found — signing and notarization will be skipped."
    echo "Copy scripts/set-apple-vars.example to scripts/set-apple-vars.sh and fill in your credentials."
fi

# ---------------------------------------------------------------
# Versions
# ---------------------------------------------------------------
SQUID_VERSION="6.12"
OPENSSL_VERSION="1.1.1w"
OPENSSL_SHA256="cf3098950cb4d853ad95c0841f1f9c6d3dc102dccfcacd521d93925208b76ac8"

SQUID_URL="http://www.squid-cache.org/Versions/v6/squid-${SQUID_VERSION}.tar.gz"
OPENSSL_URL="https://www.openssl.org/source/openssl-${OPENSSL_VERSION}.tar.gz"

INSTALL_PREFIX="/usr/local/squid"
PKG_NAME="squid-sslbump-for-webos-macos-universal"

# ---------------------------------------------------------------
# Minimum macOS deployment targets (per-arch)
# arm64: 11.0 — Apple Silicon didn't exist before Big Sur
# x86_64: 10.14 — Mojave; oldest Intel macOS supported by current Xcode CLT
# ---------------------------------------------------------------
MIN_MACOS_ARM64="11.0"
MIN_MACOS_X86_64="10.14"

# ---------------------------------------------------------------

log() { echo "" && echo "==> $*"; }

check_prereqs() {
    log "Checking prerequisites..."
    if ! xcode-select -p &>/dev/null; then
        echo "ERROR: Xcode Command Line Tools not found."
        echo "Install with: xcode-select --install"
        exit 1
    fi
    for tool in pkgbuild productbuild codesign; do
        if ! command -v "$tool" &>/dev/null; then
            echo "ERROR: $tool not found. Install Xcode Command Line Tools."
            exit 1
        fi
    done
    if [ -z "$SIGNING_IDENTITY" ]; then
        echo "ERROR: SIGNING_IDENTITY is not set in build-macos.sh."
        echo "Find yours with: security find-identity -v -p basic | grep 'Developer ID Installer'"
        exit 1
    fi
    echo "Prerequisites OK."
}

download_sources() {
    local src_dir="$BUILD_DIR/src"
    mkdir -p "$src_dir"

    log "Downloading OpenSSL $OPENSSL_VERSION..."
    local openssl_archive="$src_dir/openssl-${OPENSSL_VERSION}.tar.gz"
    if [ ! -f "$openssl_archive" ]; then
        curl -fsSL -o "$openssl_archive" "$OPENSSL_URL"
    fi
    echo "$OPENSSL_SHA256  $openssl_archive" | shasum -a 256 -c
    echo "OpenSSL checksum OK."

    log "Downloading Squid $SQUID_VERSION..."
    local squid_archive="$src_dir/squid-${SQUID_VERSION}.tar.gz"
    if [ ! -f "$squid_archive" ]; then
        curl -fsSL -o "$squid_archive" "$SQUID_URL"
    fi
}

build_openssl_arch() {
    local arch=$1   # arm64 or x86_64
    local install_dir="$BUILD_DIR/openssl-macos-$arch"

    if [ -f "$install_dir/lib/libssl.a" ]; then
        echo "OpenSSL/macos-$arch already built, skipping."
        return
    fi

    log "Building OpenSSL $OPENSSL_VERSION for macOS/$arch..."
    local build_dir="$BUILD_DIR/openssl-${OPENSSL_VERSION}-macos-$arch"
    rm -rf "$build_dir"
    tar xf "$BUILD_DIR/src/openssl-${OPENSSL_VERSION}.tar.gz" -C "$BUILD_DIR"
    mv "$BUILD_DIR/openssl-${OPENSSL_VERSION}" "$build_dir"

    pushd "$build_dir" > /dev/null
    if [ "$arch" = "arm64" ]; then
        export MACOSX_DEPLOYMENT_TARGET="$MIN_MACOS_ARM64"
        ./Configure darwin64-arm64-cc \
            --prefix="$install_dir" \
            no-shared no-tests \
            CC="clang -arch arm64"
    else
        export MACOSX_DEPLOYMENT_TARGET="$MIN_MACOS_X86_64"
        # no-asm: x86_64 inline assembly fails when cross-compiled from Apple Silicon.
        # C fallback is functionally identical; performance difference is negligible
        # for a proxy workload.
        ./Configure darwin64-x86_64-cc \
            --prefix="$install_dir" \
            no-shared no-tests no-asm \
            CC="clang -arch x86_64"
    fi
    make -j"$(sysctl -n hw.logicalcpu)"
    make install_sw
    popd > /dev/null
    rm -rf "$build_dir"
    unset MACOSX_DEPLOYMENT_TARGET
}

build_squid_arch() {
    local arch=$1   # arm64 or x86_64
    local install_dir="$BUILD_DIR/squid-macos-$arch"
    local openssl_dir="$BUILD_DIR/openssl-macos-$arch"

    if [ -f "$install_dir/usr/local/squid/sbin/squid" ]; then
        echo "Squid/macos-$arch already built, skipping."
        return
    fi

    log "Building Squid $SQUID_VERSION for macOS/$arch..."
    local build_dir="$BUILD_DIR/squid-${SQUID_VERSION}-macos-$arch"
    rm -rf "$build_dir"
    tar xf "$BUILD_DIR/src/squid-${SQUID_VERSION}.tar.gz" -C "$BUILD_DIR"
    mv "$BUILD_DIR/squid-${SQUID_VERSION}" "$build_dir"

    pushd "$build_dir" > /dev/null

    # Put -arch in CFLAGS/CXXFLAGS rather than CC so autoconf can run
    # its test programs natively (Rosetta handles x86_64 on Apple Silicon).
    # Embedding -arch in CC causes autoconf to treat it as cross-compilation
    # and skip all runtime sizeof tests, leaving SIZEOF_SIZE_T=0.
    local min_ver
    [ "$arch" = "arm64" ] && min_ver="$MIN_MACOS_ARM64" || min_ver="$MIN_MACOS_X86_64"

    export MACOSX_DEPLOYMENT_TARGET="$min_ver"
    export CC="clang"
    export CXX="clang++"
    # -Wno-deprecated-declarations: macOS LDAP API is deprecated since 10.10 but
    # Squid still builds LDAP auth helpers against it. They won't be in our package.
    export CFLAGS="-arch $arch -mmacosx-version-min=$min_ver -Wno-deprecated-declarations"
    export CXXFLAGS="-arch $arch -mmacosx-version-min=$min_ver -Wno-deprecated-declarations"
    export PKG_CONFIG_PATH="$openssl_dir/lib/pkgconfig"
    export CPPFLAGS="-I$openssl_dir/include"
    export LDFLAGS="-arch $arch -mmacosx-version-min=$min_ver -L$openssl_dir/lib"

    ./configure \
        "--prefix=/usr/local/squid" \
        "--with-openssl=$openssl_dir" \
        "--enable-ssl-crtd" \
        "--enable-icap-client" \
        "--enable-basic-auth-helpers=NCSA" \
        "--disable-esi" \
        "--disable-snmp" \
        "--without-gss" \
        "--without-kerberos" \
        "--without-ldap" \
        "--disable-auth-digest" \
        "--disable-auth-negotiate" \
        "--enable-external-acl-helpers=none" \
        "--with-default-user=squid"

    # Squid's configure emits "-W 64" (space-separated) on macOS, which clang
    # interprets as -W followed by a filename "64". Also strip -march=native,
    # which would embed build-host CPU instructions into the wrong arch slice.
    find . -name Makefile -exec sed -i '' 's/ -W 64//g; s/ -march=native//g' {} \;

    # Remove LDAP helper directories — macOS LDAP API is deprecated and the
    # arm64 library is missing. Scrub from source tree and Makefiles before build.
    find . -type d -name "LDAP" | xargs rm -rf 2>/dev/null || true
    find . -name Makefile | xargs sed -i '' 's/ LDAP//g; s/LDAP //g' 2>/dev/null || true

    make -j"$(sysctl -n hw.logicalcpu)"
    # DESTDIR stages files under $install_dir while --prefix=/usr/local/squid
    # is baked into the binary — so paths are correct at runtime after install.
    make install DESTDIR="$install_dir"

    popd > /dev/null
    rm -rf "$build_dir"

    unset CC CXX PKG_CONFIG_PATH CPPFLAGS LDFLAGS MACOSX_DEPLOYMENT_TARGET
}

make_universal() {
    log "Creating universal (fat) binaries with lipo..."

    # DESTDIR install puts files under $BUILD_DIR/squid-macos-$arch/usr/local/squid/
    local arm64_staged="$BUILD_DIR/squid-macos-arm64/usr/local/squid"
    local x86_staged="$BUILD_DIR/squid-macos-x86_64/usr/local/squid"
    local uni_dir="$BUILD_DIR/squid-macos-universal"

    rm -rf "$uni_dir"
    cp -r "$arm64_staged/." "$uni_dir/"

    # Lipo every Mach-O binary that has a matching x86_64 counterpart.
    # This covers squid, security_file_certgen, log_file_daemon, diskd,
    # unlinkd, all auth helpers, and anything else Squid installs.
    find "$uni_dir" -type f | while read -r uni_bin; do
        local rel="${uni_bin#${uni_dir}/}"
        local x86_bin="$x86_staged/$rel"
        if [ -f "$x86_bin" ] && file "$uni_bin" | grep -q "Mach-O"; then
            lipo -create "$uni_bin" "$x86_bin" -output "$uni_bin"
            echo "Universal: $rel"
        fi
    done

    echo "Universal binaries created."
    lipo -info "$uni_dir/sbin/squid"
}

build_pkg() {
    log "Assembling .pkg..."

    local pkg_root="$BUILD_DIR/pkg-root"
    local pkg_scripts="$BUILD_DIR/pkg-scripts"
    local uni_dir="$BUILD_DIR/squid-macos-universal"
    local component_pkg="$BUILD_DIR/component.pkg"

    rm -rf "$pkg_root" "$pkg_scripts"

    # Use the universal tree as payload base — all Mach-O binaries are already
    # lipo'd for arm64+x86_64. Data files (mime.conf, error pages, etc.) come
    # from the arm64 build since they are arch-independent.
    mkdir -p "$pkg_root/usr/local/squid"
    cp -r "$uni_dir/." "$pkg_root/usr/local/squid/"
    local squid_root="$pkg_root$INSTALL_PREFIX"

    # Add our custom scripts and config (overlay on top of DESTDIR)
    mkdir -p "$squid_root/bin" "$squid_root/ssl" \
             "$squid_root/var/lib" "$squid_root/var/cache" "$squid_root/var/logs" \
             "$squid_root/var/archive"
    cp "$SCRIPT_DIR/packaging/squid-init.sh" "$squid_root/bin/"
    cp "$SCRIPT_DIR/packaging/setup-server.py" "$squid_root/bin/"
    cp "$SCRIPT_DIR/packaging/archive-server.py" "$squid_root/bin/"
    cp "$SCRIPT_DIR/packaging/macos/uninstall.sh" "$squid_root/bin/uninstall.sh"
    chmod +x "$squid_root/bin/squid-init.sh" \
             "$squid_root/bin/setup-server.py" \
             "$squid_root/bin/archive-server.py" \
             "$squid_root/bin/uninstall.sh"

    # Replace the default squid.conf with our template
    cp "$SCRIPT_DIR/packaging/squid.conf.template" "$squid_root/etc/squid.conf"
    cp "$SCRIPT_DIR/packaging/macos/com.squid-sslbump-for-webos.plist" \
        "$squid_root/etc/"

    # Scripts
    mkdir -p "$pkg_scripts"
    cp "$SCRIPT_DIR/packaging/macos/postinstall" "$pkg_scripts/postinstall"
    chmod +x "$pkg_scripts/postinstall"

    # Sign ALL executables in the payload with Developer ID Application + hardened runtime.
    # Must happen after full payload is assembled so every binary gets signed.
    # Required by Apple notarization: pkg signing (Installer cert) is separate.
    if [ -n "$CODE_SIGNING_IDENTITY" ]; then
        log "Signing all payload binaries with Developer ID Application..."
        find "$squid_root" -type f -perm +111 | while read -r bin; do
            # Skip shell scripts and python files — only sign Mach-O binaries
            if file "$bin" | grep -q "Mach-O"; then
                codesign --sign "$CODE_SIGNING_IDENTITY" \
                    --options runtime \
                    --timestamp \
                    --force \
                    "$bin"
                echo "Signed: $bin"
            fi
        done
    else
        echo "WARNING: CODE_SIGNING_IDENTITY not set — binaries will not be signed."
        echo "Add CODE_SIGNING_IDENTITY to scripts/set-apple-vars.sh to enable notarization."
    fi

    # Build component package
    pkgbuild \
        --root "$pkg_root" \
        --scripts "$pkg_scripts" \
        --identifier "com.squid-sslbump-for-webos" \
        --version "$SQUID_VERSION" \
        --install-location "/" \
        --sign "$SIGNING_IDENTITY" \
        "$component_pkg"

    # Wrap in a product archive for productbuild
    # Write distribution XML to a real file — productbuild can't read /dev/fd/N
    local dist_xml="$BUILD_DIR/Distribution.xml"
    cat > "$dist_xml" <<EOF
<?xml version="1.0" encoding="utf-8"?>
<installer-gui-script minSpecVersion="2">
    <title>squid-sslbump-for-webos</title>
    <options customize="never" require-scripts="true"/>
    <choices-outline>
        <line choice="com.squid-sslbump-for-webos"/>
    </choices-outline>
    <choice id="com.squid-sslbump-for-webos" title="squid-sslbump-for-webos">
        <pkg-ref id="com.squid-sslbump-for-webos"/>
    </choice>
    <pkg-ref id="com.squid-sslbump-for-webos" version="$SQUID_VERSION" onConclusion="none">component.pkg</pkg-ref>
</installer-gui-script>
EOF

    mkdir -p "$DIST_DIR"
    productbuild \
        --distribution "$dist_xml" \
        --package-path "$BUILD_DIR" \
        --sign "$SIGNING_IDENTITY" \
        "$DIST_DIR/${PKG_NAME}.pkg"

    echo "Created: $DIST_DIR/${PKG_NAME}.pkg"
}

notarize_pkg() {
    local pkg="$DIST_DIR/${PKG_NAME}.pkg"

    if [ -z "$APPLE_ID" ] || [ -z "$APPLE_TEAM_ID" ] || [ -z "$APPLE_APP_SPECIFIC_PASSWORD" ]; then
        echo ""
        echo "Notarization skipped (APPLE_ID, APPLE_TEAM_ID, or APPLE_APP_SPECIFIC_PASSWORD not set)."
        echo "Fill in scripts/set-apple-vars.sh to enable notarization."
        return
    fi

    log "Submitting to Apple notary service..."
    xcrun notarytool submit "$pkg" \
        --apple-id "$APPLE_ID" \
        --team-id "$APPLE_TEAM_ID" \
        --password "$APPLE_APP_SPECIFIC_PASSWORD" \
        --wait

    log "Stapling notarization ticket..."
    xcrun stapler staple "$pkg"
    echo "Notarization complete."
}

main() {
    echo ""
    echo "squid-sslbump-for-webos — macOS build"
    echo "Squid $SQUID_VERSION + OpenSSL $OPENSSL_VERSION"
    echo ""

    check_prereqs
    mkdir -p "$BUILD_DIR"
    download_sources

    for arch in arm64 x86_64; do
        echo ""
        echo "----------------------------------------"
        echo " Architecture: $arch"
        echo "----------------------------------------"
        build_openssl_arch "$arch"
        build_squid_arch "$arch"
    done

    make_universal
    build_pkg
    notarize_pkg

    echo ""
    echo "========================================"
    echo " Build complete"
    echo "========================================"
    ls -lh "$DIST_DIR/"
}

main "$@"
