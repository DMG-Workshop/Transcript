#!/usr/bin/env bash
# Builds the shared library for the host platform straight from src/CMakeLists.txt,
# without going through a full Flutter app build. Used by this package's own tests
# (which load the library directly via dart:ffi) and by CI, so the FFI surface gets
# exercised against a real compiled binary rather than only analyzed.
set -euo pipefail

package_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
build_dir="$package_dir/build/native_test"

cmake -S "$package_dir/src" -B "$build_dir" -DCMAKE_BUILD_TYPE=Release
cmake --build "$build_dir" --target transcript_whisper_native -j"$(nproc)"

echo "Built: $(find "$build_dir" -maxdepth 1 -name 'libtranscript_whisper_native.*')"
