# Wi-Fi daemon shutdown crash (vendor wpa_supplicant on Android 11)

The Android 8.1 vendor `wpa_supplicant` frees one entry of its network list twice in its own
SIGTERM cleanup (`wpa_supplicant_deinit` -> `..._deinit_iface` -> `wpa_config_free`). Android
8.1's allocator tolerated it; Android 11's Scudo aborts, so **every reboot wrote a tombstone**
(29 of them by 2026-09-24). Reproduce: `kill -TERM $(pidof wpa_supplicant)`. Turning Wi-Fi off
in the UI uses HIDL `terminate()` and was never affected.

`libwpaexit.c` is preloaded into the daemon and turns its SIGTERM handler into `_exit(0)`: on a
reboot the system is going down anyway, so skipping disconnect/teardown loses nothing.

Install (done by `install/from-android.sh`; vendor partition, backup kept):

```
/vendor/lib/libwpaexit.so                               (vendor_file, 0644)
/vendor/etc/init/hw/init.common.rc, service wpa_supplicant:
    setenv LD_PRELOAD /vendor/lib/libwpaexit.so        (original: /data/local/init.common.rc.stock)
```

Verified 2026-09-24: preload mapped after boot; a reboot then wrote no tombstone; Wi-Fi
connected normally after each boot. One caveat, from a *deliberate* SIGTERM while running:
Android 11's Wi-Fi service restarted the daemon but lost track of it until the next reboot
(without the preload the same kill crashes instead). In normal use SIGTERM only comes at
shutdown.
