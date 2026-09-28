# OpenLocate mobile (Flutter)

Not scaffolded yet: the development machine for step 1 had no Flutter/Android SDK, and we
don't commit code that hasn't been built. This is the plan for step 2.

## Stack
| Concern | Choice |
|---|---|
| UI | Flutter (stable) |
| Android location | Kotlin, `FusedLocationProviderClient` inside a foreground service (`foregroundServiceType="location"`), Activity Recognition for moving/stationary |
| iOS location | Swift, `CLLocationManager` (`allowsBackgroundLocationUpdates`, `distanceFilter`, `activityType`, significant-change when stationary), `CMMotionActivityManager` |
| Bridge | Platform channels (`MethodChannel` + `EventChannel`) — one small native module per platform |
| Crypto | `sodium_libs` (libsodium, same primitives as `packages/crypto`) |
| Secure storage | `flutter_secure_storage` (Keystore / Keychain, `first_unlock_this_device`) |
| Local DB | `sqflite_sqlcipher`, key in secure storage |
| Map | `maplibre_gl`, style URL configurable (OSM-based by default) |
| QR | `mobile_scanner` (scan), `qr_flutter` (show) |
| Network | `web_socket_channel` + `http`; `flutter_webrtc` for P2P (v0.2) |

## Structure
```
apps/mobile/
├── lib/
│   ├── main.dart
│   ├── config.dart                 BACKEND_URL, TURN_SERVER, MAP_STYLE_URL via --dart-define
│   ├── crypto/                     Dart port of packages/crypto (+ shared test vectors)
│   ├── backend/
│   │   ├── backend_provider.dart   mirrors packages/client/src/provider.ts
│   │   └── http_provider.dart
│   ├── location/
│   │   ├── location_service.dart   Dart side of the platform channel
│   │   └── modes.dart              battery modes → native request parameters
│   ├── storage/                    SQLCipher history + offline queue
│   ├── maps/map_provider.dart
│   └── ui/                         map, member list, member detail, settings, pairing
├── android/app/src/main/kotlin/.../LocationService.kt
└── ios/Runner/LocationModule.swift
```

## To start step 2
Install Flutter stable, Android Studio (SDK + an emulator) and, for iOS, Xcode on a Mac. Then
`flutter create --org org.openlocate --platforms android,ios apps/mobile` and build up from
there.
