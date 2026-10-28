#!/bin/bash
# Build the ARMv7 diagnostic; C must never allocate VFP/NEON registers.
# Usage: build-vfp-canary.sh <Android-NDK-directory> [output]
set -euo pipefail
NDK=${1:?provide your Android NDK directory}
OUT=${2:-vfp-state-canary}
R=$(cd "$(dirname "$0")" && pwd)
case "$(uname -s)" in Darwin) host=darwin-x86_64;; Linux) host=linux-x86_64;; *) echo 'Use macOS or Linux' >&2;exit 1;; esac
CC=$NDK/toolchains/llvm/prebuilt/$host/bin/armv7a-linux-androideabi28-clang
[ -x "$CC" ] || { echo "Missing compiler: $CC" >&2;exit 1; }
t=$(mktemp -d)
trap 'rm -rf "$t"' EXIT
"$CC" -O2 -mfpu=none -fno-vectorize -fno-slp-vectorize -c "$R/src/vfp-state-canary.c" -o "$t/c.o"
"$CC" -c "$R/src/vfp-state-canary.S" -o "$t/asm.o"
"$CC" -static "$t/c.o" "$t/asm.o" -o "$OUT"
python3 - "$OUT" <<'PY'
import hashlib,sys
from pathlib import Path
p=Path(sys.argv[1]); print(hashlib.sha256(p.read_bytes()).hexdigest(),p)
PY
