#!/bin/bash
# Controlled device trial / rollback. Not called by the release installer.
# Uses a dedicated verified backup; refuses a different framework or concurrent patch.
set -euo pipefail
MODE=${1:?usage: trial-standby.sh install <services-standby.jar> | rollback}
ADB=${ADB:-/opt/homebrew/bin/adb}
SERIAL=${INKPALM_SERIAL:-AA006265A2391700596}
ORIGINAL=ac34b0f57e09fc32ff1e024736f7114e30464c973406e0a3204cd1d5848518d4
case "$MODE" in
  install)
    JAR=${2:?provide the built services-standby.jar}
    [ -f "$JAR" ] || { echo "Missing jar: $JAR" >&2; exit 1; }
    PATCH=$(shasum -a256 "$JAR" | awk '{print $1}')
    [ "$PATCH" != "$ORIGINAL" ] || { echo "Input is the unpatched framework" >&2; exit 1; }
    # A jar not produced by the reviewed builder must not be installed accidentally.
    [ -f "$JAR.standby-sha256" ] || { echo "Missing builder checksum receipt" >&2; exit 1; }
    [ "$(cat "$JAR.standby-sha256")" = "$PATCH" ] || { echo "Builder receipt mismatch" >&2; exit 1; }
    "$ADB" -s "$SERIAL" get-state
    "$ADB" -s "$SERIAL" push "$JAR" /data/local/tmp/inkpalm-standby-services.jar
    "$ADB" -s "$SERIAL" shell su 0 sh -s -- "$ORIGINAL" "$PATCH" <<'DEVICE'
set -eu
expected=$1
patch=$2
f=/system/framework
b=/data/local/inkpalm-standby-backup
staged=/data/local/tmp/inkpalm-standby-services.jar
file_sha256() { sha256sum "$1" | cut -d ' ' -f 1; }
[ "$(file_sha256 "$staged")" = "$patch" ] || { echo "Transferred jar hash mismatch" >&2; exit 1; }
current=$(file_sha256 "$f/services.jar")
if [ "$current" != "$expected" ]; then
  previous=$(cat "$b/previous-trial.sha256" 2>/dev/null || true)
  [ -f "$b/complete" ] && [ -f "$b/trial.sha256" ] &&
    { [ "$current" = "$(cat "$b/trial.sha256")" ] || [ "$current" = "$previous" ]; } || {
      echo "Current framework is neither original nor our recorded trial; refusing installation" >&2; exit 1;
    }
fi
# Finish an existing backup only by explicit investigation, never by overwriting it.
if [ -e "$b" ]; then
  [ -f "$b/complete" ] || { echo "Incomplete standby backup; inspect before retrying" >&2; exit 1; }
  [ "$(file_sha256 "$b/services.jar")" = "$expected" ] || exit 1
  (cd "$b" && sha256sum -c original.sha256) || exit 1
else
  mkdir -m 0700 "$b"
  cp -p "$f/services.jar" "$b/services.jar"
  mkdir "$b/oat"
  for ext in odex vdex art; do
    if [ -f "$f/oat/arm/services.$ext" ]; then
      cp -p "$f/oat/arm/services.$ext" "$b/oat/services.$ext"
    fi
  done
  (cd "$b" && sha256sum services.jar > original.sha256)
  for ext in odex vdex art; do
    if [ -f "$b/oat/services.$ext" ]; then
      (cd "$b" && sha256sum "oat/services.$ext" >> original.sha256)
    fi
  done
  [ "$(file_sha256 "$b/services.jar")" = "$expected" ] || exit 1
  (cd "$b" && sha256sum -c original.sha256) || exit 1
  sync
  touch "$b/complete"
fi
printf '%s\n' "$current" > "$b/previous-trial.sha256"
printf '%s\n' "$patch" > "$b/trial.sha256"
mount -o rw,remount /system
cp "$staged" "$f/services.jar.inkpalm-new"
chmod 0644 "$f/services.jar.inkpalm-new"
chown 0:0 "$f/services.jar.inkpalm-new"
chcon u:object_r:system_file:s0 "$f/services.jar.inkpalm-new"
[ "$(file_sha256 "$f/services.jar.inkpalm-new")" = "$patch" ] || exit 1
mv "$f/services.jar.inkpalm-new" "$f/services.jar"
# Keep removed precompiled files in the task backup too; never touch unrelated artifacts.
mkdir -p "$b/removed-oat"
for ext in odex vdex art; do
  if [ -f "$f/oat/arm/services.$ext" ]; then
    mv "$f/oat/arm/services.$ext" "$b/removed-oat/services.$ext"
  fi
done
sync
echo "Standby trial installed; rebooting. Backup: $b"
reboot
DEVICE
    ;;
  rollback)
    "$ADB" -s "$SERIAL" get-state
    "$ADB" -s "$SERIAL" shell su 0 sh -s -- "$ORIGINAL" <<'DEVICE'
set -eu
expected=$1
f=/system/framework
b=/data/local/inkpalm-standby-backup
file_sha256() { sha256sum "$1" | cut -d ' ' -f 1; }
[ -f "$b/complete" ] && [ -f "$b/trial.sha256" ] || { echo "No complete standby backup" >&2; exit 1; }
[ "$(file_sha256 "$b/services.jar")" = "$expected" ] || exit 1
(cd "$b" && sha256sum -c original.sha256) || exit 1
current=$(file_sha256 "$f/services.jar")
trial=$(cat "$b/trial.sha256")
previous=$(cat "$b/previous-trial.sha256" 2>/dev/null || true)
[ "$current" = "$trial" ] || [ "$current" = "$previous" ] || [ "$current" = "$expected" ] || { echo "Another framework change intervened; refusing rollback" >&2; exit 1; }
mount -o rw,remount /system
cp "$b/services.jar" "$f/services.jar.inkpalm-restore"
chmod 0644 "$f/services.jar.inkpalm-restore"
chown 0:0 "$f/services.jar.inkpalm-restore"
chcon u:object_r:system_file:s0 "$f/services.jar.inkpalm-restore"
[ "$(file_sha256 "$f/services.jar.inkpalm-restore")" = "$expected" ] || exit 1
mv "$f/services.jar.inkpalm-restore" "$f/services.jar"
mkdir -p "$b/trial-oat"
for ext in odex vdex art; do
  if [ -f "$f/oat/arm/services.$ext" ]; then
    mv "$f/oat/arm/services.$ext" "$b/trial-oat/services.$ext"
  fi
  if [ -f "$b/oat/services.$ext" ]; then
    cp -p "$b/oat/services.$ext" "$f/oat/arm/services.$ext"
    chcon u:object_r:system_file:s0 "$f/oat/arm/services.$ext"
    [ "$(file_sha256 "$b/oat/services.$ext")" = "$(file_sha256 "$f/oat/arm/services.$ext")" ] || exit 1
  fi
done
sync
echo "Original framework restored; rebooting"
reboot
DEVICE
    ;;
  *) echo "usage: $0 install <services-standby.jar> | rollback" >&2; exit 2 ;;
esac
