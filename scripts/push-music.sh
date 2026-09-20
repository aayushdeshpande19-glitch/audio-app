#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/env.sh 2>/dev/null || true

if [ $# -eq 0 ]; then
  echo "Usage: ./scripts/push-music.sh <path-to-music-folder-or-file>"
  echo "Example: ./scripts/push-music.sh ~/Music/MyAlbum"
  exit 1
fi

TARGET="$1"
if [ ! -e "$TARGET" ]; then
  echo "Error: File or directory not found: $TARGET"
  exit 1
fi

echo "Pushing '$TARGET' to Android emulator /sdcard/Music/..."
adb push "$TARGET" /sdcard/Music/
adb shell am broadcast -a android.intent.action.MEDIA_SCANNER_SCAN_FILE -d "file:///sdcard/Music" >/dev/null 2>&1 || true
echo "Done! Open LocalBeat and tap '+' or 'Choose music folder' to import."
