#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

if [[ -d "$ROOT/.build" ]]; then
  find "$ROOT/.build" -path "*/release/LocalTTS_LocalTTSCore.bundle" -type d -prune -exec rm -rf {} +
fi
swift build -c release --product LocalTTS

APP="$ROOT/.build/release/LocalTTS.app"
CONTENTS="$APP/Contents"
MACOS="$CONTENTS/MacOS"

rm -rf "$APP"
mkdir -p "$MACOS"
cp "$ROOT/.build/release/LocalTTS" "$MACOS/LocalTTS"
cp "$ROOT/Packaging/Info.plist" "$CONTENTS/Info.plist"
for bundle in "$ROOT"/.build/*/release/*.bundle "$ROOT"/.build/release/*.bundle; do
  if [[ -d "$bundle" ]]; then
    cp -R "$bundle" "$APP/"
  fi
done
chmod +x "$MACOS/LocalTTS"

echo "$APP"
