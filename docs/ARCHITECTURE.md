# Architecture

OpenLocate is **serverless-first and peer-to-peer where possible**. It is not "server-free":
phones can't reliably find each other without a small rendezvous service, and history has to
live somewhere while the viewer's phone is off. The server's job is kept tiny and *blind*:
it relays and stores ciphertext, and enforces who may fetch what.

```
┌────────────┐   encrypted events (WebSocket / HTTPS)   ┌──────────────────────────────┐
│  Phone A   │ ───────────────────────────────────────▶ │  Worker (stateless)          │
│  (sharer)  │                                          │   verify Ed25519 signature   │
│            │ ◀──────── WebRTC DataChannel ───────┐    │   route by group id          │
└────────────┘      (live, when P2P works)         │    └──────────────┬───────────────┘
                                                   │                   │
┌────────────┐                                     │    ┌──────────────▼───────────────┐
│  Phone B   │ ◀───────────────────────────────────┘    │  GroupDurableObject (1/group)│
│  (viewer)  │ ◀─── relayed ciphertext / history ────── │   SQLite: members, cards,    │
└────────────┘                                          │   events, invitations        │
                                                        │   hibernating WebSockets     │
                                                        │   alarm → retention deletes  │
                                                        └──────────────────────────────┘
```

## Repository layout

| Path | What | Status |
|---|---|---|
| `packages/protocol` | Wire types, limits, canonical signing strings, validation. Shared by server and TS clients. | v0.1 |
| `packages/crypto` | Reference crypto (libsodium): identity, request signing, invitations, key cards, location AEAD. | v0.1 |
| `packages/client` | `BackendProvider` interface, `HttpProvider` (speaks the protocol), sharing/keyring logic. | v0.1 |
| `backend/cloudflare` | Cloudflare Workers + SQLite Durable Objects implementation of the protocol. | v0.1 |
| `apps/mobile` | Flutter app with native location services. | Next step |
| `apps/web` | Lightweight web viewer. | v0.3 |
| `docs/` | This file, protocol, threat model, battery, self-hosting. | |

The TypeScript packages are the **reference implementation** of the protocol and crypto. The
Flutter app re-implements the same primitives with the same libsodium (`sodium_libs`) and must
pass the same behaviour; the backend tests double as an executable specification.

## Components

### Identity (no accounts)
Each install generates two key pairs locally:

- **Ed25519** identity key — signs requests, cards, and the box key.
- **X25519** box key — receives sealed key cards.

`device_id = base64url(SHA-256(sign_pk)[0..16])`. Ids are self-certifying, so the server needs
no device registry and no username/password: a request proves which device sent it by its
signature. Private keys live only in OS secure storage (Android Keystore-backed
EncryptedSharedPreferences / iOS Keychain). No phone number, IMEI or advertising id is used.

### Groups, pairing and sharing
- A group is one Durable Object, addressed by a random 128-bit id the creator picks.
- **Pairing** is a QR code / `openlocate://invite?...` link containing the backend URL, group
  id, a 32-byte single-use secret, the inviter's device id, and an expiry (default 10 min,
  max 24 h). From the secret both phones derive (libsodium KDF):
  `invite_id`, `auth_key` (server stores only `SHA-256(auth_key)`), and `mac_key` (never sent).
  The joiner proves possession with `auth_key` and sends `HMAC(mac_key, group ‖ keys)`, which
  lets the *inviter's phone* confirm that the server didn't substitute someone else's keys.
- **Sharing is per sender and per viewer, never implicitly reciprocal.** Each device has its
  own *location key* (32 bytes, XChaCha20-Poly1305) with an *epoch* counter. It sends every
  other member a **key card**: a libsodium sealed box to the recipient's X25519 key, signed by
  the sender's Ed25519 key, containing the sender's display name and — only for people it
  shares with — the location key. This is the "sender keys" pattern.
- **Revocation** = remove the viewer from the share set, generate a new key (epoch + 1), and
  send new cards to the remaining viewers. The removed person never receives the new key; the
  server also stops serving them history and live events. See `rotateKey` / `publishCards`.

### Location events
```
LocationPoint {ts, lat, lon, acc?, alt?, spd?, hdg?, bat?}     ← only useful fields
  → JSON → pad to 64-byte blocks → XChaCha20-Poly1305(key[epoch], random 24-byte nonce,
     AAD = "OL1-LOC" ‖ group ‖ device ‖ event_id ‖ epoch)
  → {event_id, epoch, payload, expires_at, store}
```
The server sees: sender device id, event id, key epoch, ciphertext length (padded), and an
expiry rounded up to the minute. It never sees coordinates, fix time, accuracy, speed or names.
The AAD prevents the server from moving a ciphertext to a different sender, event or epoch.

`event_id = <device_id>:<random>`; the server de-duplicates on it, so offline batches can be
re-sent safely.

### Live updates
While a sharer is active, the phone keeps **one WebSocket** to its group's Durable Object and
publishes over it (no HTTP request per fix). The object relays the newest point of each batch
to connected viewers and stores it for history. Sockets use the Hibernation API, so an idle
group costs nothing between messages. The same socket carries **WebRTC signaling** (SDP/ICE,
forwarded verbatim between members), letting phones open a direct DataChannel for
high-frequency live updates. If P2P fails (CGNAT, firewalls), the encrypted WebSocket relay is
the fallback — and it is always there, so P2P is an optimisation, not a dependency. A TURN
server can be configured later; it too only sees ciphertext.

### History and retention
- **Local:** every fix goes into an encrypted SQLite database on the phone (SQLCipher) first,
  with a bounded size (default 10 000 points). That is the offline queue *and* local history.
- **Server:** each event carries `expires_at = fix time + retention` (user setting: 1 h … 90 d,
  default 24 h; "never" = live-only `store: false`). The server clamps to its own
  `MAX_RETENTION_DAYS`, filters expired rows on every read, and a Durable Object alarm deletes
  them at the next expiry. Removing a member deletes all their stored events.
- **Sync after offline:** queue sorted oldest-first → encrypted → sent in batches of ≤ 200 →
  server de-duplicates by event id → viewers page with a `seq` cursor.

### Backend abstraction
The app depends only on `BackendProvider` (`packages/client/src/provider.ts`):
`createGroup, getGroup, createInvitation, revokeInvitation, joinGroup, removeMember, putCard,
getCards, publishLocation, getHistory, deleteHistory, subscribe`.

`HttpProvider` implements it over the documented HTTP/WebSocket protocol
([PROTOCOL.md](PROTOCOL.md)), so *any* server speaking that protocol works — the Cloudflare
backend here is one implementation. A backend with a different API (Firebase, Supabase, …)
implements `BackendProvider` directly. Everything crossing the interface is already encrypted.

### Maps
A `MapProvider` interface in the app; default is **MapLibre** with OpenStreetMap-based tiles
from a configurable style URL, so no proprietary API key is needed. Google/Mapbox can be added
as alternative providers.

### Configuration
Never hard-coded: `BACKEND_URL`, `TURN_SERVER`, `MAP_STYLE_URL`, `MAP_API_KEY` (optional),
`FEATURE_FLAGS`. Developer/self-hosted builds can change the backend from a settings screen;
invite links carry the backend URL, so joining a self-hosted group needs no configuration.

## Platform limitations (read before promising anything)

| | Android | iOS |
|---|---|---|
| Background location | Needs a **foreground service** of type `location` with a visible notification, plus `ACCESS_BACKGROUND_LOCATION` granted separately ("Allow all the time"). | Needs "Always" authorization, `UIBackgroundModes: location`, `allowsBackgroundLocationUpdates`, and the blue status-bar indicator / `showsBackgroundLocationIndicator`. |
| Exact intervals | Not guaranteed. Doze, app-standby buckets and OEM battery killers delay work. `FusedLocationProvider` `setMinUpdateIntervalMillis`/`setMaxUpdateDelayMillis` are hints. | Not guaranteed. The OS coalesces and pauses updates (`pausesLocationUpdatesAutomatically`). Significant-change/visits wake a terminated app only coarsely (~500 m). |
| Process killed | Foreground service survives; some OEMs still kill it (documented in the app). | Significant-change / region monitoring relaunch the app in the background; continuous updates stop until then. |
| Store review | Play requires a declaration + video justifying background location. | App Review requires clear purpose strings and user-visible benefit. |

Hence the product rule: the UI says **"Requested: every 15 s · Actual average: 21 s"**, never
"every 15 s guaranteed". No hacks (silent audio, fake VoIP, hidden jobs) — ever.

## Battery risks and mitigations
1. **GPS left on at high frequency** → movement-aware modes: stationary = low-power/significant
   change only; walking/driving = balanced/high accuracy with distance filters. Use the OS
   activity recognition (Android Activity Recognition, iOS `CMMotionActivity`) to switch.
2. **Radio wake-ups per fix** → one persistent socket while active, batching when the interval
   is short, and batching + opportunistic upload when on battery saver.
3. **Wake-locks / tight timers** → none; the OS location callbacks drive everything.
4. **P2P keep-alives** → the DataChannel is only opened while *someone is actually viewing*
   (viewer presence), otherwise updates go through the socket at the configured interval.
5. **Crypto cost** → negligible (µs per event); not a concern.

Benchmarks to run and record are defined in [BATTERY.md](BATTERY.md).

## Security risks (summary — details in [THREAT_MODEL.md](THREAT_MODEL.md))
- Server is trusted for **availability and access control**, not for **confidentiality**.
- The server could add a fake member; mitigated by invite bindings verified on the inviter's
  phone, join notifications, and safety numbers (`safetyNumber()`), since sharing requires an
  explicit per-person choice.
- Traffic metadata (who is in a group, who shares with whom, when devices are online, how many
  events) is visible to the server operator. This is documented, not hidden.

## Smallest MVP (v0.1)
1. Identity + secure storage.
2. One group, QR pairing, per-person sharing on/off.
3. Foreground + background location with interval presets (15 s … 1 h) and "stop sharing".
4. Encrypted local history and offline queue.
5. Server sync + history with default 24 h retention and automatic expiry.
6. Live updates over the WebSocket relay. (WebRTC P2P lands right after; signaling is ready.)

Everything else is in [ROADMAP.md](ROADMAP.md).

## Decision log

| # | Decision | Why | Alternatives rejected |
|---|---|---|---|
| 1 | **Flutter** UI + native location modules (Kotlin `FusedLocationProviderClient` foreground service; Swift `CLLocationManager`) via platform channels. | One UI codebase; native code where background behaviour and battery matter. | Pure-Flutter location plugins (less control over foreground service/iOS modes); two native apps (double the work). |
| 2 | **libsodium** everywhere (`libsodium-wrappers-sumo` in TS, `sodium_libs` in Dart). | Audited, identical primitives on every platform, has sealed boxes and XChaCha20-Poly1305. | WebCrypto only (no XChaCha/sealed box); custom constructions (never). |
| 3 | **Self-certifying device ids + signed requests**, no accounts. | Nothing to phish or reset; server stores no credentials. | Username/password; phone-number auth (privacy cost). |
| 4 | **Sender keys** (per-device location key distributed in sealed, signed cards) instead of one group key. | Makes non-reciprocal, per-person sharing and revocation natural; a removed viewer simply isn't sent the next key. | Single group key (everyone sees everyone); MLS (too heavy for v0.1 — may revisit for large groups). |
| 5 | **Cloudflare Workers + SQLite Durable Objects**, one object per group. | Per-group serialisation, strong consistency, hibernating WebSockets, alarms for retention, near-zero idle cost. | Always-on server (cost, ops); KV/D1 (no per-group coordination or sockets). |
| 6 | Backend behind `BackendProvider` + an **open HTTP protocol**. | Self-hosting and alternative providers without touching the app. | Cloudflare-specific client. |
| 7 | Server stores **ciphertext + expiry only**; expiry rounded to the minute by the client. | Retention must be enforceable server-side; rounding limits timing precision. | Server-side plaintext timestamps. |
| 8 | **WebSocket relay first, WebRTC as optimisation.** | Works on every network today; P2P adds complexity and can't be relied on (CGNAT). | P2P-only (breaks on many carriers). |
| 9 | **MapLibre + OSM-based tiles** by default. | No proprietary key for self-hosters. | Google Maps default. |
| 10 | **Apache-2.0**. | Permissive, patent grant. | GPL (limits some redistributors). |
