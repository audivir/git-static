#!/usr/bin/env bash
# Usage: ./build.sh [--jobs N] [--clean] [--static] [--tls mbedtls|openssl] [--rust]
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
JOBS="$(getconf _NPROCESSORS_ONLN 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 4)"
CLEAN=0
STATIC=0
TLS=mbedtls
WITH_RUST=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --jobs)
      JOBS="$2"
      shift 2
      ;;
    --clean)
      CLEAN=1
      shift
      ;;
    --static)
      STATIC=1
      shift
      ;;
    --tls)
      TLS="$2"
      shift 2
      ;;
    --rust)
      WITH_RUST=1
      shift
      ;;
    *)
      echo "Unknown argument: $1" >&2
      exit 1
      ;;
  esac
done

GLIBC_VER=2.17

OS="$(uname -s)"
ARCH="$(uname -m)"
[ "$ARCH" = arm64 ] && ARCH=aarch64

case "$TLS" in
  openssl | mbedtls) ;;
  *)
    echo "Unknown --tls: $TLS (expected mbedtls or openssl)" >&2
    exit 1
    ;;
esac

SUFFIX=""
[ "$STATIC" = 1 ] && SUFFIX="-static"
[ "$TLS" = openssl ] && SUFFIX="$SUFFIX-openssl"
WORK="$ROOT_DIR/build$SUFFIX"
PREFIX="$WORK/deps"
OUT="$WORK/out"
DIST="$ROOT_DIR/dist$SUFFIX"

case "$OS-$ARCH" in
  Linux-x86_64)
    OPENSSL_TARGET=linux-x86_64
    ZIG_TARGET=x86_64-linux-gnu.$GLIBC_VER
    ;;
  Linux-aarch64)
    OPENSSL_TARGET=linux-aarch64
    ZIG_TARGET=aarch64-linux-gnu.$GLIBC_VER
    ;;
  Darwin-aarch64)
    OPENSSL_TARGET=darwin64-arm64
    ZIG_TARGET=native
    ;;
  Darwin-x86_64)
    OPENSSL_TARGET=darwin64-x86_64
    ZIG_TARGET=native
    ;;
  *)
    echo "unsupported host $OS-$ARCH" >&2
    exit 1
    ;;
esac
RUST_TARGET="${ARCH}-unknown-linux-gnu"
if [ "$OS" = Linux ] && [ "$STATIC" = 1 ]; then
  ZIG_TARGET="${ARCH}-linux-musl"
  RUST_TARGET="${ARCH}-unknown-linux-musl"
fi
[ "$OS" = Darwin ] && RUST_TARGET="${ARCH}-apple-darwin"

MAKE="${MAKE:-$(command -v gmake || command -v make)}"
"$MAKE" --version 2>/dev/null | grep -q 'GNU Make' || {
  echo "GNU make required" >&2
  exit 1
}

if [ "$ZIG_TARGET" = native ]; then export CC="zig cc"; else export CC="zig cc -target $ZIG_TARGET"; fi
export AR="zig ar"
export RANLIB="zig ranlib"
[ "$OS" = Linux ] && export LD="zig ld.lld"

if [ "$CLEAN" = 1 ]; then
  echo ">>> cleaning $WORK and $DIST"
  rm -rf "$WORK" "$DIST"
fi
mkdir -p "$WORK/src" "$WORK/bin" "$PREFIX/include" "$PREFIX/lib"

if [ "$WITH_RUST" = 1 ]; then
  if ! command -v cargo >/dev/null; then
    [ -f "${CARGO_HOME:-$HOME/.cargo}/env" ] || {
      echo ">>> installing rustup (no git needed, plain https)"
      curl -sSf https://sh.rustup.rs | sh -s -- -y --profile minimal
    }
    # shellcheck disable=SC1091
    . "${CARGO_HOME:-$HOME/.cargo}/env"
  fi
  rustup target add "$RUST_TARGET"
  if ! command -v cc >/dev/null; then
    cat >"$WORK/bin/cc" <<'EOF'
#!/bin/sh
for a do
    shift
    case "$a" in
        -Wl,--fix-cortex-a53-843419) ;;
        *) set -- "$@" "$a" ;;
    esac
done
exec zig cc "$@"
EOF
    chmod +x "$WORK/bin/cc"
    export PATH="$WORK/bin:$PATH"
  fi
fi

cd "$WORK/src"

prepare() {
  [ -d "$1" ] && return
  if [ ! -f "$ROOT_DIR/vendor/$1/.git" ] && [ ! -d "$ROOT_DIR/vendor/$1/.git" ]; then
    echo "vendor/$1 is missing, run: git submodule update --init --depth 1" >&2
    exit 1
  fi
  echo ">>> preparing $1 ($(git -C "$ROOT_DIR/vendor/$1" describe --tags 2>/dev/null || echo unknown))"
  cp -R "$ROOT_DIR/vendor/$1" "$1"
  rm -rf "$1/.git"
}

prepare zlib
prepare "$TLS"
prepare curl
prepare git

echo ">>> zlib"
(
  cd zlib
  ./configure --static --prefix="$PREFIX"
  "$MAKE" -j"$JOBS"
  "$MAKE" install
)

if [ "$TLS" = openssl ]; then
  # no-asm: zig's assembler rejects perlasm; no-module: zig cannot link -bundle on macOS
  echo ">>> openssl"
  (
    cd openssl
    ./Configure "$OPENSSL_TARGET" \
      no-shared no-module no-asm no-tests no-docs \
      --prefix="$PREFIX" --libdir=lib --openssldir=/etc/ssl \
      CC="$CC" AR="$AR" RANLIB="$RANLIB"
    "$MAKE" -j"$JOBS"
    "$MAKE" install_sw
  )
  CURL_TLS=(--with-openssl="$PREFIX" --with-ca-fallback --without-ca-bundle --without-ca-path)
else
  echo ">>> mbedtls"
  (
    cd mbedtls
    "$MAKE" -C library -j"$JOBS" CC="$CC" AR="$AR" CFLAGS="-Os" static
    cp -R include/mbedtls include/psa "$PREFIX/include/"
    cp library/libmbedtls.a library/libmbedx509.a library/libmbedcrypto.a "$PREFIX/lib/"
  )
  # mbedtls reads every file in a CA directory, which covers all Linux layouts
  if [ "$OS" = Linux ]; then
    CURL_TLS=(--with-mbedtls="$PREFIX" --without-ca-bundle --with-ca-path=/etc/ssl/certs)
  else
    CURL_TLS=(--with-mbedtls="$PREFIX" --with-ca-bundle=/etc/ssl/cert.pem --without-ca-path)
  fi
fi

echo ">>> curl"
(
  cd curl
  [ -f configure ] || autoreconf -fi >/dev/null
  ./configure \
    --prefix="$PREFIX" \
    --disable-shared --enable-static \
    "${CURL_TLS[@]}" --with-zlib="$PREFIX" \
    --disable-ldap --disable-ldaps --disable-rtsp --disable-dict \
    --disable-telnet --disable-tftp --disable-pop3 --disable-imap \
    --disable-smb --disable-smtp --disable-gopher --disable-mqtt \
    --disable-manual --disable-docs \
    --without-libpsl --without-libidn2 --without-libssh2 --without-libgsasl \
    --without-nghttp2 --without-nghttp3 --without-ngtcp2 \
    --without-brotli --without-zstd
  "$MAKE" -j"$JOBS"
  "$MAKE" install
)

echo ">>> git"
GIT_MAKE_ARGS=(
  CC="$CC" AR="$AR" RANLIB="$RANLIB"
  CFLAGS="-Os -I$PREFIX/include"
  prefix=/usr/local
  RUNTIME_PREFIX=YesPlease
  ZLIB_PATH="$PREFIX"
  CURLDIR="$PREFIX"
  CURL_CONFIG="$PREFIX/bin/curl-config"
  CURL_LDFLAGS="$("$PREFIX/bin/curl-config" --static-libs)"
  NO_EXPAT=YesPlease NO_GETTEXT=YesPlease NO_PERL=YesPlease
  NO_PYTHON=YesPlease NO_TCLTK=YesPlease
  NO_INSTALL_HARDLINKS=YesPlease
  INSTALL_SYMLINKS=YesPlease
  LINK_FUZZ_PROGRAMS=        # lld rejects its flags
)
if [ "$OS" = Linux ]; then
  LDFLAGS="-L$PREFIX/lib"
  if [ "$STATIC" = 1 ]; then
    LDFLAGS="-static $LDFLAGS"
    GIT_MAKE_ARGS+=(NO_REGEX=NeedsStartEnd) # musl lacks REG_STARTEND
  else
    GIT_MAKE_ARGS+=(CSPRNG_METHOD=) # getrandom needs glibc 2.25
  fi
  [ "$WITH_RUST" = 1 ] && LDFLAGS="$LDFLAGS -lunwind"
else
  LDFLAGS="-L$PREFIX/lib"
  GIT_MAKE_ARGS+=(
    USE_HOMEBREW_LIBICONV= NEEDS_GOOD_LIBICONV= # use system libiconv
    LD_MAJOR_VERSION=                           # skip Xcode-ld-only flags
  )
fi
GIT_MAKE_ARGS+=(LDFLAGS="$LDFLAGS")
if [ "$TLS" = openssl ]; then
  GIT_MAKE_ARGS+=(OPENSSLDIR="$PREFIX")
else
  GIT_MAKE_ARGS+=(NO_OPENSSL=YesPlease)
fi
if [ "$WITH_RUST" = 1 ]; then
  GIT_MAKE_ARGS+=(
    CARGO_ARGS="--release --target $RUST_TARGET"
    RUST_LIB="target/$RUST_TARGET/release/libgitcore.a"
  )
else
  GIT_MAKE_ARGS+=(NO_RUST=YesPlease)
fi
(
  cd git
  "$MAKE" -j"$JOBS" "${GIT_MAKE_ARGS[@]}" all
  rm -rf "$OUT"
  "$MAKE" "${GIT_MAKE_ARGS[@]}" DESTDIR="$OUT" install
  # client-only
  for p in git-imap-send git-http-fetch git-daemon git-http-backend git-shell scalar git-cvsserver; do
    rm -f "$OUT/usr/local/libexec/git-core/$p" "$OUT/usr/local/bin/$p"
  done
  rm -rf "$DIST"
  mkdir -p "$DIST/lib"
  cp -R "$OUT/usr/local/." "$DIST/"
  cp libgit.a "$DIST/lib/"
  if [ "$WITH_RUST" = 1 ]; then cp "target/$RUST_TARGET/release/libgitcore.a" "$DIST/lib/"; fi
)

echo ">>> CA certificates"
mkdir -p "$DIST/share/git-core/certs"
(
  cd "$DIST/share/git-core/certs"
  curl -fsSLO https://curl.se/ca/cacert.pem
  curl -fsSL https://curl.se/ca/cacert.pem.sha256 | shasum -a 256 -c - >/dev/null
)

GIT_BIN="$DIST/bin/git"
echo
echo ">>> done: $GIT_BIN"
"$GIT_BIN" --version
if [ "$OS" = Linux ]; then
  if [ "$STATIC" = 1 ]; then
    if LC_ALL=C grep -a -q -E '/lib/ld-(linux|musl)' "$GIT_BIN"; then
      echo "WARNING: git references a dynamic loader, not fully static" >&2
    else
      echo "fully static"
    fi
  elif LC_ALL=C grep -a -q -E 'lib(z|ssl|crypto|curl|mbed[a-z0-9]*)\.so' "$GIT_BIN" "$DIST/libexec/git-core/git-remote-http"; then
    echo "WARNING: git links a dependency dynamically, not only glibc" >&2
  else
    echo "only glibc is dynamic"
  fi
else
  otool -L "$GIT_BIN" "$DIST/libexec/git-core/git-remote-https"
fi
