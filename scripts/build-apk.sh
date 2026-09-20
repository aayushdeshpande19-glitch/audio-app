#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/env.sh
bash scripts/create-signing-key.sh
flutter pub get
flutter analyze
flutter test
flutter build apk --release --target-platform android-arm64
mkdir -p dist
cp build/app/outputs/flutter-apk/app-release.apk dist/LocalBeat-1.0.0-arm64.apk
echo 'APK: dist/LocalBeat-1.0.0-arm64.apk'
