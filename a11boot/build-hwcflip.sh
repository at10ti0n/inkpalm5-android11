#!/bin/bash
# Build libhwcflip.so, the LD_PRELOAD shim for the vendor composer process (see libhwcflip.c).
#   NDK=<ndk>/toolchains/llvm/prebuilt/<host>/bin bash a11boot/build-hwcflip.sh [out.so]
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
NDK=${NDK:?set NDK to the toolchains/llvm/prebuilt/HOST/bin directory of an Android NDK}
OUT=${1:-$HERE/../build/libhwcflip.so}; mkdir -p "$(dirname "$OUT")"
"$NDK/armv7a-linux-androideabi28-clang" -shared -fPIC -O2 -Wall -Wformat -Wl,-z,now \
    -I"$HERE/include" -o "$OUT" "$HERE/libhwcflip.c" -ldl
echo "built $OUT sha256 $(shasum -a256 "$OUT" | cut -c1-16)"
