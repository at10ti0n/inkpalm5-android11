#!/bin/bash
# macOS: double-click to run the installer (Linux: run it from a terminal).
cd "$(dirname "$0")" || exit 1
if ! command -v python3 >/dev/null; then
  echo "Python 3 is needed. On macOS, run: xcode-select --install   (or install it from python.org)"
  read -r -p "Press Enter to close"; exit 1
fi
python3 install/inkpalm.py "$@"
read -r -p "Press Enter to close"
