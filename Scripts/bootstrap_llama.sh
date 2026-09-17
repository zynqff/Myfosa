#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
LLAMA_DIR="$ROOT/.build/llama.cpp"

# patch_q2_0c_metal.sh само клонирует chaxu01/llama.cpp @ 92c448af6
# (форк уже содержит GGML_TYPE_Q2_0C — CPU/KleidiAI dot-product,
# но без Metal) и добавляет native Metal GEMV/GEMM кернелы поверх.
"$ROOT/Scripts/patch_q2_0c_metal.sh"

cd "$LLAMA_DIR"

# Сборка iOS xcframework с включённым Metal, как и раньше.
./build-xcframework.sh

mkdir -p "$ROOT/Vendor"
rm -rf "$ROOT/Vendor/llama.xcframework"
cp -R "$LLAMA_DIR/build-apple/llama.xcframework" "$ROOT/Vendor/llama.xcframework"
echo "XCFramework (Q2_0C Metal) copied to $ROOT/Vendor/llama.xcframework"
