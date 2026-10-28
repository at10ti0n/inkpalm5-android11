#!/system/bin/sh
# Shared guarded installer: called by configure.sh, the single phase and the shell wrapper.
set -eu
mode=${1:?install or rollback}
staged=${2:-}
expected=0215e926bf20a414c325450696ce2f833a5ea272ba67cb898949787a9b3b4bcc
case "$mode" in install|rollback) ;; *) exit 2 ;; esac
b=/data/local/inkpalm-framework-recovery
target=/vendor/etc/init/inkpalm-framework-recovery.rc
file_sha256() { sha256sum "$1" | cut -d ' ' -f 1; }
# The only supported upgrade is the first, measured version of this same guard.
known_sha() {
  case "$1" in "$expected"|1baca31f712471d26798ed92f24094575e28bbfd1e96b8ed310818251e605c36) return 0 ;; *) return 1 ;; esac
}
[ "$(getprop ro.hardware)" = sun8iw15p1 ]
[ "$(getprop ro.zygote)" = zygote32 ]
# This trial was reviewed against this service definition and old init.
[ "$(file_sha256 /system/etc/init/hw/init.zygote32.rc)" = 5c9a85379fc298b6cca22f3b7f5b1dd4f7c1352760d3998acc6d2b1b32a00ae9 ] || {
  echo 'Different zygote definition; review before adapting' >&2; exit 1;
}
[ ! -L "$target" ] || { echo 'Refusing a symlink at the target' >&2; exit 1; }
if [ -e "$target" ]; then
  [ -f "$b/original-absent" ] && [ -f "$b/installed.sha256" ] &&
    known_sha "$(cat "$b/installed.sha256")" &&
    known_sha "$(file_sha256 "$target")" || {
      echo 'Unknown existing recovery rule; refusing to replace/remove' >&2; exit 1;
    }
fi
if [ "$mode" = install ]; then
  [ "$(file_sha256 "$staged")" = "$expected" ]
  if [ -e "$b" ]; then
    [ -f "$b/original-absent" ] && [ -f "$b/installed.sha256" ] &&
      known_sha "$(cat "$b/installed.sha256")" || {
        echo 'Unexpected or incomplete existing receipt; inspect before retrying' >&2; exit 1;
      }
  else
    mkdir -m 0700 "$b"
    touch "$b/original-absent"
    printf '%s\n' "$expected" > "$b/installed.sha256"
    cp "$staged" "$b/recovery.rc"
    sha256sum /system/etc/init/hw/init.zygote32.rc > "$b/zygote.sha256"
    sync
  fi
else
  [ -f "$b/original-absent" ] && [ -f "$b/installed.sha256" ] &&
    known_sha "$(cat "$b/installed.sha256")" || exit 1
fi
if [ "$mode" = install ] && [ -f "$target" ] &&
   [ "$(file_sha256 "$target")" = "$expected" ] &&
   [ "$(cat "$b/installed.sha256")" = "$expected" ]; then
  echo 'Recovery guard already installed; no files changed'
  echo '== framework recovery installed'
  exit 0
fi
mount -o rw,remount /vendor
trap 'mount -o ro,remount /vendor' EXIT
if [ "$mode" = install ]; then
  cp "$staged" "$target.new"
  chown 0:0 "$target.new"
  chmod 0644 "$target.new"
  chcon u:object_r:vendor_configs_file:s0 "$target.new"
  [ "$(file_sha256 "$target.new")" = "$expected" ]
  mv "$target.new" "$target"
  cp "$staged" "$b/recovery.rc"
  printf '%s\n' "$expected" > "$b/installed.sha256.new"
  mv "$b/installed.sha256.new" "$b/installed.sha256"
  echo "Installed $target ($expected)"
else
  # Only our exact file is removed; original state was absence.
  if [ -e "$target" ]; then rm "$target"; fi
  echo 'Recovery rule removed'
fi
sync
mount -o ro,remount /vendor
trap - EXIT
echo 'Vendor is read-only again. Reboot required to change the loaded init rules.'
[ "$mode" != install ] || echo "== framework recovery installed"
