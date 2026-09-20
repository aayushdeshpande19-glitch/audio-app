#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/env.sh 2>/dev/null || true

# If an emulator is currently running headless, stop it so the GUI window can launch
if pgrep -f "qemu-system-aarch64-headless" >/dev/null 2>&1; then
  echo "Stopping headless background emulator..."
  pkill -f "qemu-system-aarch64-headless" || true
  sleep 2
fi

# Check if GUI emulator is already running
if pgrep -f "qemu-system-aarch64" >/dev/null 2>&1; then
  echo "Android emulator is already running."
else
  echo "Starting LocalBeat Android 15 Emulator with GUI..."
  nohup emulator -avd LocalBeat_API35 -gpu auto >/dev/null 2>&1 &
fi

echo "Waiting for emulator to be ready..."
adb wait-for-device
while [ "$(adb shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" != "1" ]; do
  sleep 1
done

echo "Android Emulator is ready!"
if [ -f "dist/LocalBeat-1.0.0-arm64.apk" ]; then
  echo "Installing latest LocalBeat build..."
  adb install -r "dist/LocalBeat-1.0.0-arm64.apk"
  adb shell am start -n app.localbeat.localbeat/.MainActivity
  echo "LocalBeat launched on emulator."
fi
