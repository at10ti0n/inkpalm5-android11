# Moaan InkPalm 5 Pro (EPD105 / virgo-perf1) - minimal TWRP board config
# Gate 1F-3b skeleton. Values below are MEASURED from the stock images, not guessed.
# Anything not measured is left absent rather than filled with a plausible default.

DEVICE_PATH := device/moaan/EPD105

# --- SoC / arch (measured: uname, /proc/cpuinfo) ---
TARGET_ARCH                        := arm
TARGET_ARCH_VARIANT                := armv7-a-neon
TARGET_CPU_ABI                     := armeabi-v7a
TARGET_CPU_ABI2                    := armeabi
TARGET_CPU_VARIANT                 := cortex-a7
TARGET_BOARD_PLATFORM              := sun8iw15p1
TARGET_NO_BOOTLOADER               := true

# --- boot image (measured from stock/bimg-stock.img AND partitions/recovery.img;
#     both headers are identical, and the KERNEL IS BYTE-IDENTICAL between them:
#     sha256 c6627f3c80acdfc1..., 18,169,856 bytes) ---
BOARD_KERNEL_BASE                  := 0x40000000
BOARD_KERNEL_PAGESIZE              := 2048
BOARD_KERNEL_OFFSET                := 0x00008000    # kernel_addr 0x40008000
BOARD_RAMDISK_OFFSET               := 0x02000000    # ramdisk_addr 0x42000000
BOARD_KERNEL_TAGS_OFFSET           := 0x00000100    # tags_addr    0x40000100
BOARD_KERNEL_CMDLINE               := selinux=1 androidboot.selinux=permissive buildvariant=user
# Reuse the stock kernel verbatim. Do NOT build a kernel for the first tree.
TARGET_PREBUILT_KERNEL             := $(DEVICE_PATH)/prebuilt/kernel

# --- partitions (measured; legacy non-A/B) ---
BOARD_BOOTIMAGE_PARTITION_SIZE     := 33554432       # 32 MiB
BOARD_RECOVERYIMAGE_PARTITION_SIZE := 33554432       # 32 MiB
BOARD_FLASH_BLOCK_SIZE             := 131072
TARGET_USERIMAGES_USE_EXT4         := true
TARGET_USERIMAGES_USE_F2FS         := true           # /data is f2fs (stock fstab)
AB_OTA_UPDATER                     := false

# --- TWRP ---
TW_THEME                           := portrait_hdpi
TW_INCLUDE_CRYPTO                  := false          # NOT before first boot
TW_NO_SCREEN_TIMEOUT               := true           # e-ink: no blanking behaviour
TW_NO_SCREEN_BLANK                 := true
TW_EXCLUDE_MTP                     := true           # not before first boot
TW_EXCLUDE_TWRPAPP                 := true

# E-Ink display is driven by libepd via /dev/disp DISP_EINK_UPDATE2, NOT by fb writes.
# Gate 1A established that writing /dev/graphics/fb0 alone does NOT refresh this panel.
TW_CUSTOM_EPD_BACKEND              := true

# Frontlight (LM3630A over i2c) is INTENTIONALLY not wired up for the first build.
# It is a separate subsystem from the EPD and must not become a prerequisite for
# display bring-up.
# TW_BRIGHTNESS_PATH               := (deliberately unset)

TARGET_RECOVERY_FSTAB := $(DEVICE_PATH)/twrp.fstab
TW_EXCLUDE_DEFAULT_USB_INIT := true
# fix2 (2026-09-17): Goodix GT1158 reports X 0..1280 down the portrait screen and
# Y 0..720 across it (corner taps: TL=(151,142) BR=(1215,584)). Swap, no flips.
RECOVERY_TOUCHSCREEN_SWAP_XY       := true
