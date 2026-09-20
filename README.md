# LocalBeat

A personal, offline Android music player with a Flutter interface. Built for the Nothing Phone (1) on Android 15; minimum Android version is 8.0. The release APK targets ARM64.

## Install

1. Copy `dist/LocalBeat-1.0.0-arm64.apk` to your phone, using USB or your preferred file transfer.
2. Open the APK in your phone's file manager. If Android asks, allow that file manager to install apps, then tap Install.
3. Open LocalBeat and choose **Choose music folder**, or the folder button at the top right. Select a folder **stored on your phone** and tap **Use this folder**.
4. Wait for indexing, then tap a song. Subfolders are included automatically. You can add more folders or refresh them from Music folders.

Android restricts selecting some roots, including the entire Downloads folder and Android/data. Put music in a dedicated subfolder such as `Music/My Music` and select that folder. A remote/cloud folder is not an offline library: download its music onto the phone first.

## Included

- Songs, albums, artists, favorites, recent listening, and editable playlists.
- Search by title, artist, or album; title/artist/album/date-added sorting.
- Embedded artwork and tag extraction, with filename and artwork fallbacks.
- Play/pause, seeking, next/previous, shuffle, repeat one/all, and editable queue.
- Background playback, Android media notifications, lock-screen and headset/media controls.
- Saved queue and position, restored paused after reopening.
- MP3, AAC/M4A, FLAC, PCM WAV, Ogg Vorbis, and Opus playback through Android's playback engine.
- Incremental folder scans, bounded artwork cache, background SQLite operations, and virtualized lists.

Use a song's three-dot menu to like it, add it to a playlist, or enqueue it. Long-press a playlist song to reorder it. Queue rows also have drag handles. **Play Next** turns shuffle off so the requested next song is deterministic.

All user data stays in the app's local database. There are no accounts, servers, analytics, online artwork lookups, or network permissions in the release manifest. Original files and tags are never edited or deleted. Removing a folder hides its tracks; playlist and favorite references are retained in case it returns. Moving or renaming a file may give it a new Android document ID and therefore a new library identity.

Uninstalling the app or clearing its storage removes playlists, favorites, and history. Installing an update signed with the same key preserves app data. The app does not yet provide backup/export.

## Build from source

This build uses Flutter 3.47.5 / Dart 3.13.4, JDK 17, Android SDK 36, NDK 28.2.13676358, Gradle 9.3.1, and Android Gradle Plugin 9.1.0. `pubspec.lock` records resolved Dart dependencies. A newer dependency set has not been validated.

On the original development machine, tools were bootstrapped under `/private/tmp/localbeat-tools`. That folder is temporary and may be removed by macOS. `scripts/env.sh` can use a replacement location via `LOCALBEAT_TOOLS`; it expects `flutter/`, `java/Contents/Home/`, and `android-sdk/` under that directory. Alternatively use your own Flutter/JDK/Android SDK environment and run the Flutter commands directly.

```bash
source scripts/env.sh
bash scripts/create-signing-key.sh
flutter pub get
flutter analyze
flutter test
flutter build apk --release --target-platform android-arm64
```

`bash scripts/build-apk.sh` runs these checks and copies the APK into `dist/`. Internet is needed to install build tools and fetch dependencies, but not to use the installed app.

Keep both `android/app/localbeat-release.jks` and `android/key.properties` in a safe local backup. They are intentionally excluded from version control. The signing script refuses to overwrite an existing key. Losing this key prevents installing future builds over the existing app without uninstalling it. Do not publish the key or its properties file.

## Structure

- `lib/database.dart`: versioned SQLite schema and queries through Drift; file identities, folder membership, playlists, history, and playback persistence.
- `lib/library.dart`: platform-independent library-access interface and incremental scan controller.
- `lib/playback.dart`: audio service, playback/queue behavior, and artwork cache.
- `lib/main.dart`: application initialization, Riverpod injection, screens, and controls.
- Android Kotlin bridge: persisted Storage Access Framework permissions, paged recursive enumeration, metadata, and on-demand thumbnail extraction. Music is played directly from content URIs.

Scan pages commit in transactions. A scan reconciles removed files only after it finishes successfully. Failed/revoked folders are marked unavailable without deleting user references. Overlapping folders share a document identity while retaining separate playable URIs.

The Flutter library and screen code is reusable, but this repository currently builds Android only. macOS still needs its platform adapter, permissions, media integration, and testing.

## Validation

See `docs/VALIDATION.md` for actual checks and remaining device checks. Run automated tests with `flutter test`. The 20,000-track fixture measures database behavior on the host; it is not a claim that initial metadata extraction on a phone is instantaneous.

`bash scripts/make-audio-fixtures.sh` produces low-volume synthetic tones in each supported format for emulator/device checks. It requires FFmpeg and stores its outputs under the ignored `test-output/` directory. These fixtures are not bundled in the app.

## Deferred

Lyrics, equalizer, crossfade, sleep timer, recommendations, playlist-file import/export, syncing, and macOS delivery are outside this first version. Encrypted/DRM-protected downloads are not supported; a matching extension alone cannot guarantee codec compatibility.
