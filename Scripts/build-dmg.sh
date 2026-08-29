#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Nick Wolff <nick@wolff.tech>
# SPDX-License-Identifier: GPL-3.0-only

# Packs an app into the styled Constellation disk image: the app beside an
# Applications link on the background from Scripts/dmg. The image is not
# signed; Scripts/release.sh signs, notarizes and staples it.
#
#   Scripts/build-dmg.sh <Constellation.app> <output.dmg>
#
# dmgbuild (pure Python) writes the Finder layout directly, so no Finder
# scripting is involved and the result is the same on CI and locally. It is
# installed from Scripts/dmg/requirements.txt into a venv under .tools/.
set -euo pipefail

APP="${1:?usage: build-dmg.sh <app> <output.dmg>}"
OUTPUT="${2:?usage: build-dmg.sh <app> <output.dmg>}"
if [[ ! -d "$APP/Contents" ]]; then
  echo "$APP is not an app bundle" >&2
  exit 1
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VENV="$ROOT/.tools/dmgbuild"
REQUIREMENTS="$ROOT/Scripts/dmg/requirements.txt"

if [[ ! -x "$VENV/bin/dmgbuild" || "$REQUIREMENTS" -nt "$VENV/bin/dmgbuild" ]]; then
  echo "Installing dmgbuild into $VENV..."
  rm -rf "$VENV"
  python3 -m venv "$VENV"
  "$VENV/bin/pip" install --quiet --disable-pip-version-check \
    --require-hashes --requirement "$REQUIREMENTS"
fi

rm -f "$OUTPUT"
mkdir -p "$(dirname "$OUTPUT")"
# hdiutil occasionally reports "Resource busy" on GitHub runners; retry.
for attempt in 1 2 3; do
  if "$VENV/bin/dmgbuild" -s "$ROOT/Scripts/dmg/settings.py" \
      -D app="$(cd "$(dirname "$APP")" && pwd)/$(basename "$APP")" \
      -D background="$ROOT/Scripts/dmg/background.png" \
      Constellation "$OUTPUT"; then
    break
  fi
  if [[ "$attempt" == 3 ]]; then
    echo "dmgbuild failed after $attempt attempts" >&2
    exit 1
  fi
  echo "dmgbuild failed (attempt $attempt); retrying..." >&2
  sleep 5
done
echo "Disk image ready: $OUTPUT"
