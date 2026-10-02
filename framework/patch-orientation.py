#!/usr/bin/env python3
"""Stop Android 11 letterboxing apps that ask for the display's natural orientation.

WindowContainer.getRequestedConfigurationOrientation() maps screenOrientation="nosensor"
(5) to DisplayContent.getNaturalOrientation(). This panel is natively 1280x720 and runs
rotated to portrait, so natural = landscape, and apps such as KOReader and Launcher3 are
letterboxed into a 720x405 box. On a device with no sensors, "nosensor" asks for nothing
that differs from "unspecified", so return ORIENTATION_UNDEFINED (0): the app takes
whatever orientation the user chose (Orientation tile). getNaturalOrientation() has no
other caller in this build. Usage: patch-orientation.py <WindowContainer.smali>"""
import sys
p = sys.argv[1]
s = open(p).read()
OLD = """    iget-object v0, p0, Lcom/android/server/wm/WindowContainer;->mDisplayContent:Lcom/android/server/wm/DisplayContent;

    if-eqz v0, :cond_3

    .line 1131
    invoke-virtual {v0}, Lcom/android/server/wm/DisplayContent;->getNaturalOrientation()I

    move-result v0

    return v0
"""
NEW = """    # inkpalm: nosensor = no requirement (natural orientation is landscape on this panel)
    const/4 v0, 0x0

    return v0
"""
if "# inkpalm: nosensor" in s:
    sys.exit("already patched")
assert s.count(OLD) == 1, "unexpected getRequestedConfigurationOrientation() body; not patched"
open(p, "w").write(s.replace(OLD, NEW))
print("patched", p)
