#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

if command -v brew >/dev/null 2>&1; then
  BREW_PREFIX="$(brew --prefix)"
else
  BREW_PREFIX="/opt/homebrew"
fi

if [[ -z "${CPLUS_INCLUDE_PATH:-}" ]]; then
  sdk_path="$(xcrun -sdk macosx --show-sdk-path 2>/dev/null || true)"
  if [[ -n "$sdk_path" && -d "$sdk_path/usr/include/c++/v1" ]]; then
    export CPLUS_INCLUDE_PATH="$sdk_path/usr/include/c++/v1"
  fi
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
RESOURCES="$CONTENTS/Resources"
FRAMEWORKS="$CONTENTS/Frameworks"

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
"$ROOT/Scripts/build-mlx-metallib.sh" release "$MACOS" >&2

sparrowhawk_runtime_log="$ROOT/.build/sparrowhawk-runtime-build.log"
if ! "$ROOT/Scripts/build-sparrowhawk-runtime.sh" > "$sparrowhawk_runtime_log" 2>&1; then
  cat "$sparrowhawk_runtime_log" >&2
  exit 1
fi
sparrowhawk_runtime="$(tail -n 1 "$sparrowhawk_runtime_log" | tr -d '\r')"
if [[ -n "$sparrowhawk_runtime" && -x "$sparrowhawk_runtime/bin/nemo_normalizer_main" ]]; then
  mkdir -p "$RESOURCES/Sparrowhawk" "$FRAMEWORKS/Sparrowhawk"

  run_install_name_tool() {
    local output
    if ! output="$(install_name_tool "$@" 2>&1)"; then
      printf "%s\n" "$output" >&2
      return 1
    fi
  }

  cp "$sparrowhawk_runtime/bin/nemo_normalizer_main" "$MACOS/LocalTTSNemoNormalizer"
  cp "$sparrowhawk_runtime/lib/libsparrowhawk.0.dylib" "$FRAMEWORKS/Sparrowhawk/"
  cp -R "$sparrowhawk_runtime/share/." "$RESOURCES/Sparrowhawk/"

  sparrowhawk_dylib_targets=(
    "$MACOS/LocalTTSNemoNormalizer"
    "$FRAMEWORKS/Sparrowhawk/libsparrowhawk.0.dylib"
  )
  copied_sparrowhawk_dylibs="|$FRAMEWORKS/Sparrowhawk/libsparrowhawk.0.dylib|"

  copy_sparrowhawk_dependency() {
    local dependency="$1"
    case "$dependency" in
      "")
        return
        ;;
    esac
    if [[ "$dependency" == @rpath/* ]]; then
      dependency="$BREW_PREFIX/lib/$(basename "$dependency")"
    elif [[ "$dependency" == @loader_path/* ]]; then
      dependency="$FRAMEWORKS/Sparrowhawk/$(basename "$dependency")"
    fi
    case "$dependency" in
      @*|/usr/lib/*|/System/*)
        return
        ;;
    esac
    if [[ ! -f "$dependency" ]]; then
      return
    fi

    local dependency_name
    dependency_name="$(basename "$dependency")"
    local dependency_destination="$FRAMEWORKS/Sparrowhawk/$dependency_name"
    if [[ "$copied_sparrowhawk_dylibs" == *"|$dependency_destination|"* ]]; then
      return
    fi

    cp -L "$dependency" "$dependency_destination"
    chmod u+w "$dependency_destination"
    copied_sparrowhawk_dylibs="$copied_sparrowhawk_dylibs$dependency_destination|"
    sparrowhawk_dylib_targets+=("$dependency_destination")

    while read -r nested_dependency; do
      copy_sparrowhawk_dependency "$nested_dependency"
    done < <(otool -L "$dependency_destination" | awk 'NR > 1 { print $1 }')
  }

  while read -r dependency; do
    copy_sparrowhawk_dependency "$dependency"
  done < <(otool -L "$MACOS/LocalTTSNemoNormalizer" "$FRAMEWORKS/Sparrowhawk/libsparrowhawk.0.dylib" | awk 'NF > 1 && $1 !~ /:$/ { print $1 }')

  sparrowhawk_dylib_targets=()
  while read -r dylib_target; do
    sparrowhawk_dylib_targets+=("$dylib_target")
  done < <(find "$FRAMEWORKS/Sparrowhawk" -maxdepth 1 -type f -name "*.dylib" | sort)
  sparrowhawk_install_name_targets=(
    "$MACOS/LocalTTSNemoNormalizer"
    "${sparrowhawk_dylib_targets[@]}"
  )

  for dylib_target in "${sparrowhawk_install_name_targets[@]}"; do
    chmod u+w "$dylib_target"
  done

  for _rewrite_pass in 1 2 3; do
    for dylib_target in "${sparrowhawk_install_name_targets[@]}"; do
      if [[ "$dylib_target" == *.dylib ]]; then
        run_install_name_tool -id "@loader_path/$(basename "$dylib_target")" "$dylib_target"
      fi
      while read -r dependency; do
        case "$dependency" in
          ""|@loader_path/*|@executable_path/*|/usr/lib/*|/System/*)
            continue
            ;;
        esac
        dependency_name="$(basename "$dependency")"
        if [[ ! -f "$FRAMEWORKS/Sparrowhawk/$dependency_name" ]]; then
          continue
        fi
        if [[ "$dylib_target" == "$MACOS/LocalTTSNemoNormalizer" ]]; then
          replacement="@executable_path/../Frameworks/Sparrowhawk/$dependency_name"
        else
          replacement="@loader_path/$dependency_name"
        fi
        run_install_name_tool -change "$dependency" "$replacement" "$dylib_target"
      done < <(otool -L "$dylib_target" | awk 'NR > 1 { print $1 }')
    done
  done

  chmod +x "$MACOS/LocalTTSNemoNormalizer"
  for dylib_target in "${sparrowhawk_install_name_targets[@]}"; do
    codesign --force --sign - "$dylib_target" >/dev/null 2>&1
  done

  sparrowhawk_smoke_output="$(printf "We achieved a 20,000× performance improvement.\n" | "$MACOS/LocalTTSNemoNormalizer" --path_prefix="$RESOURCES/Sparrowhawk")"
  if [[ "$sparrowhawk_smoke_output" != "We achieved a twenty thousand times performance improvement." ]]; then
    echo "Sparrowhawk normalizer smoke check failed: $sparrowhawk_smoke_output" >&2
    exit 1
  fi
fi

chmod +x "$MACOS/LocalTTS"

echo "$APP"
