#!/bin/sh
# Build mtmd_shape_probe against the local llama.cpp-omni build tree.
set -e

HERE=$(cd "$(dirname "$0")" && pwd)
ROOT="$HERE/../../MiniCPM-V-Apps/llama.cpp-omni"
BIN="$ROOT/build-mac-ref/bin"

clang++ -std=c++17 -O2 \
    -I "$ROOT/tools/mtmd" \
    -I "$ROOT/include" \
    -I "$ROOT/ggml/include" \
    "$HERE/mtmd_shape_probe.cpp" \
    -L "$BIN" -lmtmd -lllama -lggml -lggml-base \
    -Wl,-rpath,"$BIN" \
    -o "$HERE/mtmd_shape_probe"

echo "built $HERE/mtmd_shape_probe"
