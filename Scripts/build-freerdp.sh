#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Nick Wolff <nick@wolff.tech>
# SPDX-License-Identifier: GPL-3.0-only

# Builds FreeRDP from the pinned Vendor/freerdp submodule as static arm64
# libraries and wraps them (with OpenSSL) in FreeRDPKit.xcframework. Output:
#   Vendor/build/freerdp/FreeRDPKit.xcframework  (library only)
#   Vendor/build/freerdp/headers                 (freerdp/ and winpr/)
# Needs CMake and the Xcode command line tools. `build-openssl.sh` downloads
# and builds the pinned OpenSSL release. Rerun after bumping either dependency.
# LTO is off because xcodebuild cannot wrap bitcode archives in an xcframework.
# WITH_INTERNAL_MD4/MD5/RC4 compile WinPR's own hash/cipher code so NTLM (NLA)
# never needs OpenSSL 3's legacy provider, which is a separate dylib that a
# hardened-runtime app cannot dlopen — without this, NLA fails after the TLS
# handshake with ERRCONNECT_CONNECT_TRANSPORT_FAILED.
#
# The default client channel set is built: rdpdr is required during connection
# setup and it in turn registers rdpsnd, so rdpsnd stays in with only its
# no-op "fake" backend (WITH_MACAUDIO=OFF keeps AVFoundation out; audio is
# deferred). Channels needing external libraries or frameworks are off so the
# app links no Homebrew dylibs: microphone capture, remote assistance, USB,
# cameras, media/FFmpeg, Kerberos, smartcard, serial, parallel and printer.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="$ROOT/Vendor/freerdp"
BUILD="$SRC/build"
PREFIX="$ROOT/Vendor/build/freerdp"
XCFRAMEWORK="$PREFIX/FreeRDPKit.xcframework"
DEPLOYMENT_TARGET="15.0"
BUILD_TYPE="${FREERDP_BUILD_TYPE:-Release}"
JOBS="$(getconf _NPROCESSORS_ONLN 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 4)"

if [[ ! -f "$SRC/CMakeLists.txt" ]]; then
  echo "Vendor/freerdp is empty. Run: git submodule update --init" >&2
  exit 1
fi
command -v cmake >/dev/null || { echo "cmake not found (brew install cmake)" >&2; exit 1; }
"$ROOT/Scripts/build-openssl.sh"
OPENSSL="$ROOT/Vendor/build/openssl"

echo "Using $(cmake --version | head -1), $(clang --version | head -1)"
echo "Building FreeRDP ($BUILD_TYPE) from $(git -C "$SRC" rev-parse --short HEAD) with OpenSSL at $OPENSSL"

rm -rf "$BUILD" "$PREFIX"
cmake -S "$SRC" -B "$BUILD" \
  -DCMAKE_BUILD_TYPE="$BUILD_TYPE" \
  -DCMAKE_OSX_ARCHITECTURES=arm64 \
  -DCMAKE_OSX_DEPLOYMENT_TARGET="$DEPLOYMENT_TARGET" \
  -DCMAKE_INSTALL_PREFIX="$PREFIX" \
  -DOPENSSL_ROOT_DIR="$OPENSSL" \
  -DOPENSSL_USE_STATIC_LIBS=ON \
  -DCMAKE_INTERPROCEDURAL_OPTIMIZATION=OFF \
  -DWITH_INTERNAL_MD4=ON \
  -DWITH_INTERNAL_MD5=ON \
  -DWITH_INTERNAL_RC4=ON \
  -DBUILD_SHARED_LIBS=OFF \
  -DBUILD_TESTING=OFF \
  -DBUILTIN_CHANNELS=ON \
  -DWITH_CLIENT_COMMON=ON \
  -DWITH_CLIENT_SDL=OFF \
  -DWITH_CLIENT_MAC=OFF \
  -DWITH_SERVER=OFF \
  -DWITH_SAMPLE=OFF \
  -DWITH_MANPAGES=OFF \
  -DWITH_WINPR_TOOLS=OFF \
  -DWITH_CCACHE=OFF \
  -DWITH_CLANG_FORMAT=OFF \
  -DWITH_FFMPEG=OFF \
  -DWITH_SWSCALE=OFF \
  -DWITH_DSP_FFMPEG=OFF \
  -DWITH_CAIRO=OFF \
  -DWITH_JPEG=OFF \
  -DWITH_OPUS=OFF \
  -DWITH_PKCS11=OFF \
  -DWITH_KRB5=OFF \
  -DWITH_JSON_DISABLED=ON \
  -DWITH_SMARTCARD_EMULATE=OFF \
  -DWITH_X11=OFF \
  -DCHANNEL_AUDIN=OFF \
  -DWITH_MACAUDIO=OFF \
  -DCHANNEL_REMDESK=OFF \
  -DCHANNEL_URBDRC=OFF \
  -DCHANNEL_RDPEAR=OFF \
  -DCHANNEL_RDPECAM=OFF \
  -DCHANNEL_TSMF=OFF \
  -DCHANNEL_VIDEO=OFF \
  -DCHANNEL_SMARTCARD=OFF \
  -DCHANNEL_SERIAL=OFF \
  -DCHANNEL_PARALLEL=OFF \
  -DCHANNEL_PRINTER=OFF

cmake --build "$BUILD" --parallel "$JOBS"
cmake --install "$BUILD" >/dev/null

# One archive keeps SwiftPM's binary target simple: FreeRDP, WinPR and the
# OpenSSL it was built against.
merged="$PREFIX/lib/libFreeRDPKit.a"
# Channel "-common" helper archives are not installed, so gather every archive
# from the build tree (skipping cmake's LTO probe).
archives=()
while IFS= read -r archive; do archives+=("$archive"); done < <(find "$BUILD" -name '*.a' -not -path '*/CMakeFiles/*' | sort)
libtool -static -no_warning_for_no_symbols -o "$merged" \
  "${archives[@]}" \
  "$OPENSSL/lib/libssl.a" \
  "$OPENSSL/lib/libcrypto.a"

# Headers are deliberately NOT packed into the xcframework: Xcode copies every
# binary target's headers into one shared include directory, where GhosttyKit's
# umbrella module map would claim them and hide their declarations. The C
# bridge reads them through the package's FreeRDPHeaders symlink instead.
headers="$PREFIX/headers"
rm -rf "$headers" "$XCFRAMEWORK"
mkdir -p "$headers"
/usr/bin/ditto "$PREFIX/include/freerdp3" "$headers"
/usr/bin/ditto "$PREFIX/include/winpr3" "$headers"
xcodebuild -create-xcframework -library "$merged" -output "$XCFRAMEWORK" >/dev/null

echo "Built $XCFRAMEWORK and $headers"
echo "System libraries FreeRDP expects (from pkg-config):"
grep -h "Libs.private" "$PREFIX"/lib/pkgconfig/*.pc | sort -u
