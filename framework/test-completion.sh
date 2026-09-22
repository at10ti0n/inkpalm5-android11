#!/bin/bash
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
AJ=${AJ:-/opt/homebrew/share/android-commandlinetools/platforms/android-27/android.jar}
W=$(mktemp -d)
trap 'rm -rf "$W"' EXIT
javac -source 8 -target 8 -bootclasspath "$AJ" -d "$W" "$HERE/StandbyScreen.java" "$HERE/CompletionGateTest.java"
java -cp "$W:$AJ" com.android.server.power.CompletionGateTest
