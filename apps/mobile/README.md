# OpenLocate mobile (Flutter)

Android beta. iOS comes later (needs a Mac or a cloud macOS build plus an Apple Developer account).

## Get a test build
- **Beta releases:** download the `.apk` from the repository's
  [Releases](../../../releases) page (pre-releases), on your Android phone.
- **Every push:** the *Android* workflow attaches an APK artifact to each run.

Test instructions and known limitations for testers are in [BETA_NOTES.md](BETA_NOTES.md).

## How it's built
Only `lib/`, `test/`, `pubspec.yaml` and the customised
`android/app/src/main/AndroidManifest.xml` are committed. CI runs
`flutter create --platforms android --org org.openlocate --project-name openlocate .` to generate
the remaining standard Gradle/Flutter files (it never overwrites committed files), then
`flutter analyze`, `flutter test` and `flutter build apk`.

Locally (with Flutter stable and the Android SDK):

```bash
cd apps/mobile
flutter create --platforms android --org org.openlocate --project-name openlocate .
flutter test
flutter run --dart-define=BACKEND_URL=https://your-backend.example
```

## Layout
| Path | What |
|---|---|
| `lib/crypto/ol_crypto.dart` | Dart port of `packages/crypto` (libsodium via `sodium`), verified byte-for-byte against `packages/crypto/test/vectors.json` |
| `lib/backend/` | `BackendProvider` interface + `HttpProvider` (protocol v1) |
| `lib/state/app_state.dart` | Identity, group, key cards, sharing, live connection, offline queue |
| `lib/location/tracker.dart` | Foreground-service location via `geolocator` (visible notification; no background hacks) |
| `lib/ui/` | Welcome, map + members, invite QR, scanner, member history, settings |

## Configuration (`--dart-define`)
| Name | Default | Meaning |
|---|---|---|
| `BACKEND_URL` | empty (asked on first run) | OpenLocate server; CI uses the `BACKEND_URL` repository variable |
| `MAP_TILE_URL` | OpenStreetMap tiles | Raster tile template; use your own tile server for wide distribution |
| `APP_VERSION` | `dev` | Shown in Settings |

## Dependencies worth knowing
- `mobile_scanner` uses Google ML Kit on Android (proprietary, bundled model). Planned
  replacement: an open-source ZXing-based scanner.
- `geolocator` uses Google Play Services' fused provider when available and falls back to the
  platform `LocationManager` otherwise.
