#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Nick Wolff <nick@wolff.tech>
# SPDX-License-Identifier: GPL-3.0-only

# Packages the complete corresponding source for a Constellation release.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="${1:-}"
REVISION="${SOURCE_REVISION:-HEAD}"

if [[ -z "$VERSION" || ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z.-]+)?$ ]]; then
  echo "usage: $0 <version> [output.zip]" >&2
  exit 1
fi

OUTPUT="${2:-$ROOT/build/release/$VERSION/Constellation-$VERSION-source.zip}"
if [[ "$OUTPUT" != /* ]]; then
  OUTPUT="$PWD/$OUTPUT"
fi
STAGING="$(mktemp -d "${TMPDIR:-/tmp}/constellation-source.XXXXXX")"
TREE="$STAGING/Constellation-$VERSION"
trap 'rm -rf "$STAGING"' EXIT

mkdir -p "$TREE"

copy_worktree() {
  local path
  while IFS= read -r -d '' path; do
    case "$path" in
      Vendor/ghostty|Vendor/freerdp) continue ;;
    esac
    [[ -e "$ROOT/$path" || -L "$ROOT/$path" ]] || continue
    mkdir -p "$TREE/$(dirname "$path")"
    /bin/cp -pP "$ROOT/$path" "$TREE/$path"
  done < <(git -C "$ROOT" ls-files -z --cached --others --exclude-standard)
}

if [[ "$REVISION" == "WORKTREE" ]]; then
  copy_worktree
else
  git -C "$ROOT" rev-parse --verify "$REVISION^{commit}" >/dev/null
  git -C "$ROOT" archive --format=tar "$REVISION" | tar -xf - -C "$TREE"
fi

for submodule in Vendor/ghostty Vendor/freerdp; do
  if [[ "$REVISION" == "WORKTREE" ]]; then
    commit="$(git -C "$ROOT/$submodule" rev-parse HEAD)"
  else
    commit="$(git -C "$ROOT" ls-tree "$REVISION" -- "$submodule" | awk '{print $3}')"
  fi
  if [[ -z "$commit" ]]; then
    echo "could not determine $submodule revision" >&2
    exit 1
  fi
  if [[ "$(git -C "$ROOT/$submodule" rev-parse HEAD)" != "$commit" ]]; then
    echo "$submodule is not checked out at $commit" >&2
    exit 1
  fi
  mkdir -p "$TREE/$submodule"
  git -C "$ROOT/$submodule" archive --format=tar "$commit" | tar -xf - -C "$TREE/$submodule"
done

resolved_files=(
  "$ROOT/Packages/ConstellationInfrastructure/Package.resolved"
  "$ROOT/Packages/ConstellationRemoteDesktop/Package.resolved"
)
swift_pins="$(/usr/bin/python3 -c '
import json, sys
pins = {}
for path in sys.argv[1:]:
    with open(path, encoding="utf-8") as source:
        for pin in json.load(source)["pins"]:
            pins[pin["identity"]] = pin["state"]["revision"]
for identity, revision in sorted(pins.items()):
    print(f"{identity}\t{revision}")
' "${resolved_files[@]}")"

shopt -s nullglob
checkout_candidates=(
  "$ROOT"/Packages/*/.build/checkouts/*
  "$ROOT"/build/SourcePackages/checkouts/*
  "$HOME"/Library/Developer/Xcode/DerivedData/*/SourcePackages/checkouts/*
)
swift_count=0
while IFS=$'\t' read -r identity revision; do
  [[ -n "$identity" ]] || continue
  checkout=""
  for candidate in "${checkout_candidates[@]}"; do
    if git -C "$candidate" cat-file -e "$revision^{commit}" 2>/dev/null; then
      checkout="$candidate"
      break
    fi
  done
  if [[ -z "$checkout" ]]; then
    echo "Swift package source for $identity at $revision was not found" >&2
    exit 1
  fi
  destination="$TREE/Dependencies/Swift/$identity-${revision:0:12}"
  mkdir -p "$destination"
  git -C "$checkout" archive --format=tar "$revision" | tar -xf - -C "$destination"
  swift_count=$((swift_count + 1))
done <<< "$swift_pins"

openssl_version="$(sed -n 's/^OPENSSL_VERSION="\([^"]*\)"/\1/p' "$ROOT/Scripts/build-openssl.sh")"
openssl_archive="$ROOT/.tools/openssl-$openssl_version.tar.gz"
if [[ ! -f "$openssl_archive" ]]; then
  echo "$openssl_archive is missing; run Scripts/build-openssl.sh first" >&2
  exit 1
fi
mkdir -p "$TREE/Dependencies/Native"
/bin/cp -p "$openssl_archive" "$TREE/Dependencies/Native/$(basename "$openssl_archive")"

zig_cache="${ZIG_GLOBAL_CACHE_DIR:-$HOME/.cache/zig}"
zig_archives=("$zig_cache"/p/*.tar.gz)
if (( ${#zig_archives[@]} == 0 )); then
  echo "no Zig dependency source archives found in $zig_cache/p" >&2
  exit 1
fi
mkdir -p "$TREE/Dependencies/Zig"
for archive in "${zig_archives[@]}"; do
  /bin/cp -p "$archive" "$TREE/Dependencies/Zig/$(basename "$archive")"
done

test -f "$TREE/LICENSE"
test -f "$TREE/Scripts/build-libghostty.sh"
test -f "$TREE/Scripts/build-freerdp.sh"
test -f "$TREE/Vendor/ghostty/build.zig"
test -f "$TREE/Vendor/freerdp/CMakeLists.txt"
test "$swift_count" -gt 0

mkdir -p "$(dirname "$OUTPUT")"
rm -f "$OUTPUT" "$OUTPUT.sha256"
(
  cd "$STAGING"
  COPYFILE_DISABLE=1 /usr/bin/zip -q -r -y -X "$OUTPUT" "$(basename "$TREE")"
)
(
  cd "$(dirname "$OUTPUT")"
  shasum -a 256 "$(basename "$OUTPUT")" > "$(basename "$OUTPUT").sha256"
)

echo "Packaged corresponding source at $OUTPUT"
