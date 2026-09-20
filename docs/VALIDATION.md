# LocalBeat Validation

Date: 20 September 2026
Build: 1.0.0+1, `dist/LocalBeat-1.0.0-arm64.apk`
SHA-256: `60a0c8af40d3505153bccb0790042e24e195cdf8f1948fcfe47af42abf51276c`
Size: ~24.7 MB, ARM64 release, signed (CN=LocalBeat, O=Personal, C=IN).

## Automated checks (this session)

- `flutter analyze`: No issues found.
- `flutter test`: All 12 tests passed.
  - 20,000-track fixture: ingest ~419 ms; search + groups + full listing + restore ~129 ms (host database measurement, not phone indexing).
- Release build: `flutter build apk --release --target-platform android-arm64` succeeded.
- Signature: `apksigner verify --print-certs` passes, same LocalBeat key as prior build.
- Permissions (`aapt dump permissions`): `WAKE_LOCK`, `FOREGROUND_SERVICE`, `FOREGROUND_SERVICE_MEDIA_PLAYBACK` only. No `INTERNET`, no `ACCESS_NETWORK_STATE`.

## Emulator checks (this session)

Device: `emulator-5554`, AVD `LocalBeat_API35` (Android 15 ARM64 path, SDK 35/36 toolchain).

- Installed `dist/LocalBeat-1.0.0-arm64.apk` over the previous build with `-r` (no data clear): Success.
- Launched `app.localbeat.localbeat/.MainActivity` via `am start`: Success.
- `dumpsys media_session` after relaunch:
  - Session `app.localbeat.localbeat/media-session/9`, `state=PAUSED`, `position=30069`, `active item id=3`, `queue size=8`.
  - Metadata: `Evening Signal · m4a / LocalBeat Sessions / After Hours`.
  - `error=null`, custom Stop action present with resolved icon (no `IllegalArgumentException: You must specify an icon resource id`).
  - `logcat -s flutter:E AndroidRuntime:E`: no errors.
- This confirms the `res/raw/keep.xml` resource-keep fix survives a clean release rebuild, and that queue/position restore survives an in-place update.

## Layout fixes (this session, not yet screenshot-verified)

- `NowPlayingScreen` (`lib/main.dart`): artwork size is now `min(widthBudget, heightBudget).clamp(150, 420)` with a ~470 px reserve for title/seek/controls/footer plus `MediaQuery.padding.bottom`. Gaps shrink on heights < 700 px. Bottom padding includes the system inset. Previously `(maxWidth - 56).clamp(150, 420)` pushed the pause button behind the 3-button nav bar (see `test-output/now-playing.png`).
- Home hero (`lib/main.dart`): compact variant below 750 px height (padding 16 vs 22, title 26 vs 32, reduced gaps). `EmptyLibrary`: icon 76 vs 92, vertical padding 12 vs 28, tighter spacing so the "Choose music folder" CTA is initially visible on 1080x1920 (see `test-output/home-empty.png`, which predates this fix).
- Existing screenshots under `test-output/` are pre-fix. Re-capture on the emulator before claiming visual sign-off.

## Previously verified (carried over, not re-run end-to-end this session)

- Folder picker grant, recursive import of 8 synthetic tracks from `/sdcard/Music/LocalBeatTest/Evening/`, library listing, artwork fallback, playback progress observed.
- Formats imported but not each individually playback/seek tested: MP3, FLAC, WAV, Ogg Vorbis, Opus, M4A, raw AAC.

## Not yet validated — do not claim

- Active foreground playback, notification/lock-screen controls, screen-off and background playback after the fix (state reporting verified; controls not exercised this session).
- Per-format playback/seeking/transitions and corrupt-file behavior.
- Playlist CRUD/reorder, queue manipulation, favorites, search, sorting, shuffle/repeat, album/artist browsing, folder removal, permission revocation flows on device.
- Embedded artwork (fixtures have none); artwork cache invalidation for changed files.
- Airplane mode, process kill/relaunch beyond the update-restore check above, interrupted scans, changed/missing files.
- Nothing Phone (1) / Android 15 acceptance: Bluetooth/headset controls, calls and audio interruptions, Nothing OS battery restrictions.
- Backup/export (not implemented by design for v1).
