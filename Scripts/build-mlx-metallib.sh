#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG="${1:-debug}"
DESTINATION_DIR="${2:-}"
METAL_DIR="$ROOT/.build/checkouts/mlx-swift/Source/Cmlx/mlx-generated/metal"

if ! xcrun -sdk macosx --find metal >/dev/null 2>&1; then
  echo "Skipping MLX metallib build: xcrun cannot find the Metal compiler. Install/select full Xcode to enable Misaki MLX fallback." >&2
  exit 0
fi

if [[ ! -d "$METAL_DIR" ]]; then
  echo "Skipping MLX metallib build: $METAL_DIR is missing." >&2
  exit 0
fi

BIN_DIR="$(swift build -c "$CONFIG" --show-bin-path)"
WORK_DIR="$ROOT/.build/LocalTTS-MLXMetal-$CONFIG"
rm -rf "$WORK_DIR"
mkdir -p "$WORK_DIR"

kernels=(
  "arg_reduce"
  "conv"
  "gemv"
  "layer_norm"
  "random"
  "rms_norm"
  "rope"
  "scaled_dot_product_attention"
  "steel/attn/kernels/steel_attention"
)

air_files=()
for kernel in "${kernels[@]}"; do
  source="$METAL_DIR/$kernel.metal"
  output="$WORK_DIR/${kernel//\//_}.air"
  xcrun -sdk macosx metal \
    -x metal \
    -Wall \
    -Wextra \
    -fno-fast-math \
    -Wno-c++17-extensions \
    -Wno-c++20-extensions \
    -mmacosx-version-min=15.0 \
    -c "$source" \
    -I"$METAL_DIR" \
    -o "$output"
  air_files+=("$output")
done

xcrun -sdk macosx metallib "${air_files[@]}" -o "$BIN_DIR/mlx.metallib"
echo "$BIN_DIR/mlx.metallib"

if [[ -n "$DESTINATION_DIR" ]]; then
  mkdir -p "$DESTINATION_DIR"
  cp "$BIN_DIR/mlx.metallib" "$DESTINATION_DIR/mlx.metallib"
fi
