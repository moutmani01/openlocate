# OpenLocate

**Private, lightweight, open-source location sharing.**

- ✓ Android & iOS *(mobile app in progress — see [status](#status))*
- ✓ Live location, with a configurable desired update interval
- ✓ End-to-end encrypted location and history — the server only stores ciphertext
- ✓ Sharing is per person and never automatically reciprocal
- ✓ History that deletes itself (default 24 h)
- ✓ Peer-to-peer where possible, serverless relay everywhere else
- ✓ No accounts, no phone number — a key pair on your device
- ✓ Self-hostable in a few commands
- ✓ No ads, no analytics, no selling location data

OpenLocate is **serverless-first and peer-to-peer where possible**, not "server-free": phones
need a tiny rendezvous service to find each other and to hold history while you're offline.
That service is blind — it sees encrypted blobs, never where you are.

## Status

| Part | State |
|---|---|
| Protocol v1, crypto, threat model | ✅ Specified and implemented (TypeScript reference) |
| Cloudflare backend | ✅ Implemented, 21 end-to-end tests |
| Flutter mobile app | ⬜ Next milestone ([apps/mobile](apps/mobile/README.md)) |
| Web viewer | ⬜ v0.3 |

See [docs/ROADMAP.md](docs/ROADMAP.md).

## Architecture

```
Phone A ──encrypt──▶ Worker ──▶ Group Durable Object ──▶ Phone B ──decrypt
   └──────────── WebRTC DataChannel (when P2P works) ───────────┘
```

- Each device has an Ed25519 + X25519 key pair; its id is a hash of its public key.
- Pairing is a short-lived, single-use QR code.
- Each person encrypts their locations with their own key (XChaCha20-Poly1305) and hands that
  key, in a sealed and signed "key card", only to the people they choose.
- Removing someone rotates the key; they can't read anything new.

Full details: [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) ·
[docs/PROTOCOL.md](docs/PROTOCOL.md) · [docs/THREAT_MODEL.md](docs/THREAT_MODEL.md)

## Permissions (mobile)

| Permission | Why | When |
|---|---|---|
| Location while using | show you on the map | first launch of the map |
| Background location ("Allow all the time" / "Always") | keep sharing with the screen off | only when you turn sharing on |
| Notifications | Android requires a visible notification while sharing in the background | when sharing starts |
| Camera | scan an invite QR code | when you tap *Scan* |

Sharing is **off** by default. When it's on, the app always shows who can see you, how often
it intends to update, how long history is kept, and a one-tap *Stop*.

## Privacy

See [PRIVACY.md](PRIVACY.md). Short version: locations are encrypted on your phone; the
server keeps ciphertext only until it expires; no analytics, ads, or trackers.

## Self-hosting

```bash
git clone https://github.com/<organization>/openlocate.git && cd openlocate
npm install
npx wrangler login
npm run deploy:backend
```

Then point the app at your server. Full guide: [docs/SELF_HOSTING.md](docs/SELF_HOSTING.md).

## Development

Requires Node.js 22+.

```bash
npm install
npm test            # crypto unit tests + end-to-end backend tests on local workerd
npm run typecheck
npm run dev:backend # local backend on http://localhost:8787
```

| Path | Contents |
|---|---|
| `packages/protocol` | Wire types, limits, signing rules |
| `packages/crypto` | libsodium reference crypto |
| `packages/client` | `BackendProvider` interface, HTTP provider, sharing/keyring logic |
| `backend/cloudflare` | Cloudflare Workers + SQLite Durable Objects backend |
| `apps/mobile` | Flutter app (next) |
| `docs` | Architecture, protocol, threat model, battery, self-hosting, roadmap |

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md). Security issues: [SECURITY.md](SECURITY.md).

## License

[Apache-2.0](LICENSE)
