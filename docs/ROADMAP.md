# Roadmap

Work proceeds in small, always-buildable steps (see the playbook order below). ✅ = done.

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
