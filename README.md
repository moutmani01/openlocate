# OpenLocate

**Private, lightweight, open-source location sharing.**

- ✓ Android *(beta)* · iOS planned — see [status](#status)
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
| Android app (Flutter) | 🧪 Beta — APKs on the Releases page ([apps/mobile](apps/mobile/README.md)) |
| iOS app | ⬜ Needs macOS build + Apple Developer account |
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

## Set up your own free server (no technical skills needed)

OpenLocate needs a small "server" so phones can find each other. You can run your own for free
on Cloudflare in about 15 minutes, using only your web browser. Your locations are encrypted
before they leave the phone, so even your own server can't read them.

**You need:** a free [GitHub](https://github.com/signup) account and a free
[Cloudflare](https://dash.cloudflare.com/sign-up) account. No credit card, no installing anything.

### Step 1 — Make your own copy of OpenLocate
1. Sign in to GitHub and open [github.com/moutmani01/openlocate](https://github.com/moutmani01/openlocate).
2. Click **Fork** (top right), then **Create fork**. You now have your own copy.
3. In your copy, click the **Actions** tab. If you see a green button saying
   *"I understand my workflows, go ahead and enable them"*, click it.

### Step 2 — Prepare Cloudflare
1. Sign in to the [Cloudflare dashboard](https://dash.cloudflare.com).
2. In the left menu, click **Workers & Pages**. If Cloudflare asks you to choose a
   **workers.dev subdomain**, type a name (for example `smithfamily`) and confirm.
   Your server address will end with `.smithfamily.workers.dev`.
3. Find your **Account ID**: on the Workers & Pages page it is shown on the right side
   (or under *Account home* → the ⋯ menu next to your account → *Copy account ID*).
   Copy it into a note — you'll need it in Step 3.
4. Create a key that lets GitHub install the server for you:
   - Click your profile icon (top right) → **My Profile** → **API Tokens** → **Create Token**.
   - Next to **Edit Cloudflare Workers**, click **Use template**.
   - Under *Account Resources*, choose your account. Under *Zone Resources*, choose **All zones**.
     Leave everything else as it is.
   - Click **Continue to summary** → **Create Token**.
   - Copy the token shown (a long line of letters and numbers) into your note.
     Cloudflare shows it **only once**. Treat it like a password.

### Step 3 — Give the two values to GitHub
1. In **your copy** on GitHub, click **Settings** → **Secrets and variables** → **Actions**.
2. Click **New repository secret**:
   - Name: `CLOUDFLARE_API_TOKEN` — Secret: the token from Step 2 → **Add secret**.
3. Click **New repository secret** again:
   - Name: `CLOUDFLARE_ACCOUNT_ID` — Secret: the Account ID from Step 2 → **Add secret**.

### Step 4 — Install the server
1. Click the **Actions** tab → **Deploy backend** (left list) → **Run workflow** → **Run workflow**.
2. Wait 2–3 minutes until the run shows a green ✓. (A red ✗ usually means a secret was
   pasted wrong — fix it in Step 3 and run again.)
3. Find your server address: in Cloudflare, open **Workers & Pages** → **openlocate**. The
   address looks like `https://openlocate.smithfamily.workers.dev`.
4. Check it works: open that address followed by `/v1/info` in your browser, e.g.
   `https://openlocate.smithfamily.workers.dev/v1/info`. You should see a short line of text
   starting with `{"protocol_version":1`.

### Step 5 — Use it in the app
1. Install the app ([Releases](https://github.com/moutmani01/openlocate/releases) page, on your Android phone).
2. Enter your name, paste your server address into **Server**, and tap **Create group**.
3. Tap the invite icon and let family members scan the QR code. Their phones use your server
   automatically — they don't need to type anything.

**Costs:** Cloudflare's free plan comfortably covers a family (it allows 100,000 requests a
day). If you ever go over, the server simply pauses until the next day; you are never charged
unless you choose a paid plan yourself.

**Updating your server later:** on your copy's GitHub page click **Sync fork** → **Update
branch**. If the server part changed, it re-installs itself automatically (or run
**Deploy backend** again by hand).

**Removing everything:** delete the *openlocate* Worker in Cloudflare (Workers & Pages →
openlocate → Settings → Delete). All stored locations are erased with it.

Prefer the command line, or hosting somewhere else? See [docs/SELF_HOSTING.md](docs/SELF_HOSTING.md).

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
| `apps/mobile` | Flutter app (Android beta) |
| `docs` | Architecture, protocol, threat model, battery, self-hosting, roadmap |

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md). Security issues: [SECURITY.md](SECURITY.md).

## License

[Apache-2.0](LICENSE)
