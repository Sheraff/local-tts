#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

if [[ -z "${CPLUS_INCLUDE_PATH:-}" ]]; then
  for cxx_include in /Library/Developer/CommandLineTools/SDKs/MacOSX*.sdk/usr/include/c++/v1; do
    if [[ -d "$cxx_include" ]]; then
      export CPLUS_INCLUDE_PATH="$cxx_include"
      break
    fi
  done
fi

if [[ -d "$ROOT/.build" ]]; then
  find "$ROOT/.build" \
    \( -path "*/release/LocalTTS_LocalTTSCore.bundle" -o -path "*/release/espeak-ng_data.bundle" \) \
    -type d -prune -exec rm -rf {} +
fi
swift build -c release --product LocalTTS

APP="$ROOT/.build/release/LocalTTS.app"
CONTENTS="$APP/Contents"
MACOS="$CONTENTS/MacOS"

rm -rf "$APP"
mkdir -p "$MACOS"
cp "$ROOT/.build/release/LocalTTS" "$MACOS/LocalTTS"
cp "$ROOT/Packaging/Info.plist" "$CONTENTS/Info.plist"
copied_bundles="|"
for bundle in "$ROOT"/.build/*/release/*.bundle "$ROOT"/.build/release/*.bundle; do
  if [[ -d "$bundle" ]]; then
    bundle_dir="$(cd "$(dirname "$bundle")" && pwd -P)"
    bundle_path="$bundle_dir/$(basename "$bundle")"
    if [[ "$copied_bundles" == *"|$bundle_path|"* ]]; then
      continue
    fi
    copied_bundles="$copied_bundles$bundle_path|"
    rm -rf "$APP/$(basename "$bundle")"
    cp -R "$bundle" "$APP/"
  fi
done
chmod +x "$MACOS/LocalTTS"

echo "$APP"
