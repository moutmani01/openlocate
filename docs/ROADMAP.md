# Roadmap

Work proceeds in small, always-buildable steps (see the playbook order below). ✅ = done.

## Priorities (October 2026)

The order of work, agreed on 2026-10-12. The version lists further down are still the feature
inventory; this section says what comes first and why. Privacy is the first constraint on every
item: nothing here may let a server, including the project's own, learn where anyone is.

### 1. Reliability and diagnostics — now

A location app is dropped the first time it shows a stale position, so this comes before any
new feature.

- ⬜ **Find the Android crash.** The beta sometimes stops with Android's "app stopped" dialog.
  Capture the cause first (see the next item), then fix it.
- ⬜ **On-device diagnostic log.** Catch every uncaught error (`FlutterError.onError`,
  `PlatformDispatcher.onError`, a guarded zone around `main`) and record Android's own reason
  for the last exit (`ApplicationExitInfo`: crash, not responding, low memory, killed by the
  system or the user). Keep a short rolling log on the device with coordinates, keys and
  identifiers stripped.
- ⬜ **"Send diagnostic report" button.** The user sees exactly what will be sent and chooses
  to share it. Nothing is ever uploaded automatically. This follows the logging rules in
  [THREAT_MODEL.md](THREAT_MODEL.md).
- ⬜ **Tracking that survives the screen being closed.** Today the location stream, the
  encryption and the upload all run in the app's UI process. Move them into a real foreground
  service that keeps running when the app is swiped away, and restarts after the system kills it.
- ⬜ **Offline queue on disk.** Unsent fixes are kept in memory and are lost if the app is
  killed. Store the already-encrypted events locally until they are delivered.
- ⬜ **Battery-optimisation guidance.** Ask for the exemption when sharing is turned on, and
  explain the extra step some manufacturers need (Xiaomi, Huawei, Samsung, OnePlus).
- ⬜ **Tell people when sharing has stopped.** A notification on the sharer's phone when
  tracking ends unexpectedly, and a clear "last updated" age for everyone watching.
- ⬜ **Restart after reboot** (optional, off by default).
- ⬜ **Soak tests.** 24-hour runs on at least a Pixel, a Samsung and a Xiaomi phone, with the
  requested and actual update intervals published in [BATTERY.md](BATTERY.md).
- ⬜ **Decide on background location permission.** The app deliberately asks only for
  "while in use". Confirm that this is enough once tracking runs in its own service.

### 2. Map privacy

- ⬜ Stop loading tiles from `tile.openstreetmap.org`, which sees every phone's address and the
  areas it views.
- ⬜ Serve tiles through the project's own Worker, with OpenFreeMap (rebuilt weekly from
  OpenStreetMap) behind it, and switch the app to MapLibre vector maps as planned in
  [ARCHITECTURE.md](ARCHITECTURE.md).

### 3. A public server that can pay for itself

The code stays open source and self-hosting stays free and complete. The hosted server charges
a small amount for convenience, without learning who anyone is.

- ⬜ **Gate the public server.** Today anyone with the address can create groups on it.
- ⬜ **Prepaid vouchers.** One voucher pays for one group for a year. Vouchers are redeemed in
  the app.
- ⬜ **Unlinkable redemption.** Use blind signatures (the Privacy Pass technique) so the server
  can check that a voucher is paid without being able to link it to a purchase.
- ⬜ **Payment routes.** Card payments on a website, plus an anonymous route such as cash by
  post or a privacy coin. Check app-store billing rules before selling inside the app.
- ⬜ **Terms and privacy notice** for the hosted service, with advice on EU privacy law.
- ⬜ **Check the name.** Confirm "OpenLocate" does not collide with an existing project or
  trademark before building a brand on it.

### 4. Features that help the app spread

- ⬜ Temporary share links with a web viewer ("follow my trip for an hour", no install needed).
- ⬜ Pause for an hour / until tomorrow.
- ⬜ Arrival and departure alerts, computed on the phone.
- ⬜ Regular reminders of who can see you, as a safeguard against covert tracking.
- ⬜ iOS app.

### 5. Before 1.0

- ⬜ External security review.
- ⬜ Replace the Google ML Kit QR scanner with an open-source one.
- ⬜ Fixed signing key for releases, reproducible builds, F-Droid.

### Not planned

Chat, social features, advertising, analytics, and any automatic upload of logs.

## v0.1 — MVP
- ✅ Architecture, protocol, threat model, repository (step 1)
- ✅ Device cryptographic identity (step 6, reference implementation)
- ✅ Pairing: invitations, QR/link format, join binding (step 7, protocol + backend)
- ✅ Backend: groups, membership, key cards, encrypted events, history, automatic expiry,
  WebSocket relay + WebRTC signaling, replay protection, rate limits (step 8)
- ✅ Encrypted sync protocol with de-duplication and paging (step 9, protocol + backend)
- ✅ Mobile shell: Flutter app, map (flutter_map + OSM tiles), settings (step 2) — Android beta
- ✅ Android location tracking as a foreground service (step 3); ⬜ iOS Core Location
- ✅ Configurable desired interval + requested/actual display, battery modes (step 4)
- 🟨 Offline queue (in memory); ⬜ local encrypted history on disk (SQLCipher) (step 5)
- ✅ Identity, QR pairing, per-person sharing, key rotation, live sync in the app (steps 6, 7, 9)
- ✅ Stop sharing; ⬜ pause 1 h / pause until tomorrow
- ✅ APK builds in GitHub Actions; `v*` tags publish beta pre-releases

## v0.2
Multiple groups · history map with time ranges · configurable retention UI · offline sync UI ·
battery modes · temporary share links · member permissions UI · automatic key rotation on
removal · WebRTC DataChannel live updates (step 10).

## v0.3
Web client · Docker/workerd self-hosting · alternative backend implementations · TURN
fallback · geofencing and arrival/departure notifications · benchmark reports.

## v1.0
Android, iOS, Web; P2P + serverless relay; encrypted history; self-hosting; multiple groups;
reliable background tracking; published battery benchmarks; external security review.
