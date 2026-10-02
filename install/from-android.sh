#!/bin/bash
# Configure Android 11 (step 7 of the manual route in INSTALL.md). A front end to
# install/inkpalm.py's configure phase; the device-side work is install/device/configure.sh.
#   bash install/from-android.sh <assets-dir>
# Applies the one-time defaults (portrait, timeouts, radios off). UPDATE=1 keeps your settings.
# Optional: SF_PATCH=1 (SurfaceFlinger freeze workaround), ORIENT_PATCH=1 (full-screen KOReader).
set -euo pipefail
A=${1:?usage: from-android.sh <assets-dir>}
opts=(configure --assets "$A" --yes)
[ "${UPDATE:-0}" = 1 ] || opts+=(--first-time)
[ "${SF_PATCH:-0}" = 1 ] && opts+=(--sf-patch)
[ "${ORIENT_PATCH:-0}" = 1 ] && opts+=(--orient-patch)
exec python3 "$(dirname "$0")/inkpalm.py" "${opts[@]}"
