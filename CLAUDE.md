# Project status and working notes

This file lets a new Claude Code session (or a person) pick up the work where it stopped.
Last updated: 2026-10-12, at release `v0.1.0-beta.2`.

## What this is

OpenLocate is private, end-to-end encrypted location sharing: no accounts, keys on the device,
and a server that stores only ciphertext. See [README.md](README.md) and the documents in
[docs/](docs/).

| Part | Where | State |
| --- | --- | --- |
| Android app (Flutter) | `apps/mobile` | Beta |
| Backend (Cloudflare Worker + Durable Objects with SQLite) | `backend/cloudflare` | Deployed |
| Protocol, crypto and client reference (TypeScript) | `packages/` | Implemented, tested |
| iOS app, web viewer | — | Not started |

## The owner's priorities

1. **Privacy comes first.** Nothing may let a server, including the project's own, learn where
   anyone is. This rules out automatic log uploads, analytics and third-party trackers.
2. **Battery.** The background service must do as little as possible; the update interval the
   user chooses should be what decides battery use.
3. **Open source stays complete.** Self-hosting is free and full-featured. The hosted server may
   charge a small amount, without learning who anyone is.

The ordered plan is the "Priorities" section of [docs/ROADMAP.md](docs/ROADMAP.md). Follow that
order.

## How to work on it

- **App changes go on a branch and a pull request.** The Android workflow builds an APK for
  every pull request that touches `apps/mobile`; the owner installs it and tests on a phone
  before merging.
- **Releases.** Pushing a tag `v*` builds the APK and publishes a GitHub pre-release with
  `apps/mobile/BETA_NOTES.md` as its notes. Tags so far: `v0.1.0-beta.1`, `v0.1.0-beta.2`, `v0.1.0-beta.3` (2026-10-22: relay choice, per-IP relay limits; did not open), `v0.1.0-beta.4` (2026-10-22: fixes beta.3 not opening).
- **Backend deploys itself.** A push to `main` that touches `backend/cloudflare/**` or
  `packages/protocol/**` runs the "Deploy backend" workflow, which uses the repository secrets
  `CLOUDFLARE_API_TOKEN` and `CLOUDFLARE_ACCOUNT_ID`.
- **Checks.** Root: `npm ci`, `npm run typecheck`, `npm test`. App, in `apps/mobile`:
  `flutter analyze --no-fatal-infos` and `flutter test`.
- **Only part of the app is committed.** In `apps/mobile`, only `lib/`, `test/`, `pubspec.yaml`,
  `pubspec.lock` and the customised `AndroidManifest.xml` are tracked. The lock file is committed
  since 2026-10-22 so CI builds the dependency versions that were tested: beta.3 picked up
  `shared_preferences_android` 2.5.x unseen and did not open. CI generates the rest with
  `flutter create`. Running Flutter locally creates files such as
  `android/local.properties` and `.flutter-plugins-dependencies`, and may edit
  `analysis_options.yaml`: do not commit those.
- **Facts.** Do not invent claims about security or battery life. Measure, or say it is untested.

## The owner's server

The backend is deployed on the owner's Cloudflare account as the Worker named `openlocate`, at
`https://openlocate.mahfoudoutmani0.workers.dev`. Since 2026-10-21 it is the app's **default
relay** (the owner's decision): CI release builds get it through the repository variable
`BACKEND_URL`, and people can choose a **private relay** (their own server) when creating a
group. The address is therefore public. It is still not gated, so it relies on per-IP limits
(group creation 3 a minute, all requests 300 a minute, per Cloudflare location, in
`backend/cloudflare/wrangler.toml`) on top of the per-group limits. Gating is on the roadmap.

Each group stays on the relay it was created on; invitations carry that relay's address, so
people who join use it automatically.

History is stored in one SQLite database per group, inside a Durable Object. Tables: `events`
(encrypted location payloads with an expiry), `members`, `cards`, `invitations`, `nonces`.

## How the app tracks location (since `v0.1.0-beta.2`)

- `lib/location/sharing_service.dart` runs in an Android foreground service with its own
  isolate. It has no timer and no open connection: it wakes when Android delivers a location,
  encrypts it, appends it to the queue and sends the queue in one HTTPS request. A single retry
  timer (30 s growing to 15 min) exists only while something is undelivered.
- `lib/location/disk_queue.dart` keeps already-encrypted events in a file until the server
  accepts them.
- `lib/location/tracker.dart` is the app's handle on the service: start, stop, reload, flush.
- `lib/location/sharing_config.dart` reads keys and preferences from the same storage the app
  writes, so the service can run without the app.
- `lib/state/app_state.dart` no longer tracks. It receives fixes and the queue length from the
  service while the app is open, and tells the service when keys or preferences change.
- Only the *Maximum accuracy* mode holds a wake lock.
- "While in use" location permission is enough to share with the screen off. "Allow all the
  time" is optional and only lets Android restart the service by itself.

## Done so far

1. Backend deployed to Cloudflare through the GitHub workflow.
2. Roadmap rewritten with agreed priorities.
3. Background sharing service, on-disk queue, battery-exemption prompt, the "Background
   reliability" settings section, and notices when sharing pauses or had stopped.

## Reliability work

`docs/RELIABILITY.md` holds the freshness target, the `adb` commands for collecting evidence from
a phone, the ranked crash suspects and the emulator results. An Android 15 emulator runs on the
owner's machine (SDK in `/root/sdk/android`, JDK 21 in `/root/sdk/jdk21`, AVD `api35`); see that
file for the flags it needs.

## Open items

Needs the owner, with a phone:

- **Test `v0.1.0-beta.2` on real phones.** It passed analysis, 20 unit tests and the APK build,
  but had never run on a device when it was released. Check: sharing continues after the app is
  swiped away; positions taken in airplane mode arrive afterwards; battery use and update delay
  overnight in *Balanced* mode.
- **The Android crash.** Earlier betas sometimes stopped with Android's "app stopped" dialog.
  The cause was never identified. To capture it: `adb logcat -d -b crash > crash.txt`. Two
  unconfirmed suspects in the old code were restarting the location service at launch and the
  lack of error handling during start-up.

Next in the roadmap:

- On-device diagnostic log with a "Send diagnostic report" button. Nothing uploads by itself.
- A watchdog that alerts when Android kills the app outright.
- A heartbeat so someone standing still does not look stale in the distance-filtered modes.
- Map privacy: stop loading tiles from `tile.openstreetmap.org`; serve them through the
  project's own Worker with OpenFreeMap behind it, and move the app to MapLibre.
- Gate the public server; prepaid vouchers redeemed with blind signatures.

## Decisions already made

- Diagnostics are an on-device log that the user chooses to send. No automatic upload.
- Map data stays OpenStreetMap. The preferred source is the project's own Worker in front of
  OpenFreeMap (updated weekly), chosen for privacy first and freshness second.
- Payment for the hosted server is prepaid credit for one group, redeemed anonymously, not a
  subscription tied to a person.
- Chat, social features, advertising and analytics are not planned.
- If someone is removed from a group while the sharer's app is closed, the service keeps using
  the current key until the app next opens. This is accepted for now because the server already
  refuses the removed member.

## Things to verify before relying on them

- Whether the name "OpenLocate" collides with an existing project or trademark.
- Current terms and limits of OpenFreeMap and of Cloudflare's free tier.
- App-store billing rules, before selling anything inside the app.
