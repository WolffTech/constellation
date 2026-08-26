#!/usr/bin/env bash
# Builds the pinned OpenSSL source release for arm64 macOS. FreeRDP links the
# resulting static libraries into FreeRDPKit, so no OpenSSL dylib ships in the
# app. Bump OPENSSL_VERSION and OPENSSL_SHA256 together.
set -euo pipefail

OPENSSL_VERSION="3.5.8"
OPENSSL_SHA256="a8f84a39918ec6415ce765d9b429d313ba97b8143169c172e734b9514464f5b2"
DEPLOYMENT_TARGET="15.0"
OPENSSL_TARGET="darwin64-arm64-cc"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TOOLS="$ROOT/.tools"
VENDOR_BUILD="$ROOT/Vendor/build"
ARCHIVE_NAME="openssl-$OPENSSL_VERSION.tar.gz"
ARCHIVE="$TOOLS/$ARCHIVE_NAME"
SOURCE="$TOOLS/openssl-$OPENSSL_VERSION"
PREFIX="$VENDOR_BUILD/openssl"
STAMP="$PREFIX/.constellation-build"

command -v curl >/dev/null || { echo "curl is required" >&2; exit 1; }
command -v make >/dev/null || { echo "make is required" >&2; exit 1; }
command -v perl >/dev/null || { echo "perl is required" >&2; exit 1; }
command -v xcrun >/dev/null || { echo "Xcode command line tools are required" >&2; exit 1; }

clang="$(xcrun --find clang)"
sdk="$(xcrun --sdk macosx --show-sdk-path)"
toolchain="$(xcodebuild -version | tr '\n' ' ')"
jobs="$(getconf _NPROCESSORS_ONLN 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 4)"
script_hash="$(shasum -a 256 "${BASH_SOURCE[0]}" | awk '{print $1}')"
recipe="OpenSSL $OPENSSL_VERSION; sha256 $OPENSSL_SHA256; recipe $script_hash; target $OPENSSL_TARGET; macOS $DEPLOYMENT_TARGET; SDK $sdk; $toolchain"

if [[ -f "$PREFIX/lib/libssl.a" && -f "$PREFIX/lib/libcrypto.a" && -f "$STAMP" ]] &&
   [[ "$(<"$STAMP")" == "$recipe" ]]; then
  echo "Using cached OpenSSL $OPENSSL_VERSION at $PREFIX"
  exit 0
fi

mkdir -p "$TOOLS" "$VENDOR_BUILD"
if [[ ! -f "$ARCHIVE" ]]; then
  echo "Downloading OpenSSL $OPENSSL_VERSION..."
  curl --fail --location --silent --show-error \
    --output "$ARCHIVE" \
    "https://github.com/openssl/openssl/releases/download/openssl-$OPENSSL_VERSION/$ARCHIVE_NAME"
fi
echo "$OPENSSL_SHA256  $ARCHIVE" | shasum -a 256 -c - >/dev/null

rm -rf "$SOURCE" "$PREFIX"
tar -xzf "$ARCHIVE" -C "$TOOLS"

echo "Building OpenSSL $OPENSSL_VERSION for arm64 macOS $DEPLOYMENT_TARGET..."
(
  cd "$SOURCE"
  export CC="$clang"
  export MACOSX_DEPLOYMENT_TARGET="$DEPLOYMENT_TARGET"
  export CFLAGS="-isysroot $sdk -mmacosx-version-min=$DEPLOYMENT_TARGET"
  export LDFLAGS="-isysroot $sdk -mmacosx-version-min=$DEPLOYMENT_TARGET"
  ./Configure "$OPENSSL_TARGET" \
    no-shared \
    no-tests \
    no-docs \
    --prefix="$PREFIX" \
    --openssldir="$PREFIX/ssl"
  make --silent --jobs "$jobs"
  make --silent install_sw
)

cp "$SOURCE/LICENSE.txt" "$PREFIX/LICENSE.txt"
printf '%s\n' "$recipe" > "$STAMP"

"$PREFIX/bin/openssl" version
echo "Built static OpenSSL libraries at $PREFIX"
