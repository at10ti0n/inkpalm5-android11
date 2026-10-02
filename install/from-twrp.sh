#!/bin/bash
# Write Android 11 from TWRP (step 5 of the manual route in INSTALL.md). A front end to
# install/inkpalm.py's twrp-install phase; the device-side work is install/device/twrp-install.sh.
#   bash install/from-twrp.sh <gsi.img or gsi.img.xz> <assets-dir>
# Wipes data and cache (internal storage is kept) if that was not done yet, writes and reads
# back system and boot, installs the vendor files, then waits for the first boot.
set -euo pipefail
exec python3 "$(dirname "$0")/inkpalm.py" twrp-install --gsi "${1:?usage: from-twrp.sh <gsi> <assets-dir>}" --assets "${2:?usage: from-twrp.sh <gsi> <assets-dir>}"
