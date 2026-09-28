# Self-hosting

The backend is a single Cloudflare Worker with a SQLite-backed Durable Object per group. A
family-sized deployment typically fits in Cloudflare's free/entry tiers because idle groups
hibernate and cost nothing.

## 1. Create a provider account
Create a Cloudflare account. Durable Objects with SQLite storage are available on the Workers
Free plan (check current limits in Cloudflare's docs).

## 2. Clone
```bash
git clone https://github.com/<organization>/openlocate.git
cd openlocate
npm install
```
Requires Node.js 22+.

## 3. Configure
Edit `backend/cloudflare/wrangler.toml`:

| Setting | Meaning | Default |
|---|---|---|
| `name` | Worker name (becomes `<name>.<account>.workers.dev`) | `openlocate` |
| `MAX_RETENTION_DAYS` | Hard cap on stored history | `90` |
| `ALLOWED_ORIGIN` | CORS origin for a web client | `*` |
| `[observability] enabled` | Cloudflare request logs. Keep **off**. | `false` |

## 4. Deploy
```bash
npx wrangler login
npm run deploy:backend
```
Test it: `curl https://<your-worker>/v1/info` should return `{"protocol_version":1,...}`.
Optionally attach a custom domain in the Cloudflare dashboard (TLS is automatic).

## 5. Point the app at it
In the app: *Settings → Advanced → Server* (self-hosted/developer builds), or build with
`--dart-define=BACKEND_URL=https://your-domain`. Invite links carry the backend URL, so people
you invite join your server automatically.

## 6. Pair
Create a group, show the QR code, and have the other person scan it.

## Local development
```bash
npm run dev:backend     # wrangler dev on http://localhost:8787, local SQLite storage
npm test                # crypto unit tests + end-to-end backend tests (runs local workerd)
```

## Other hosts
The app depends only on the protocol in [PROTOCOL.md](PROTOCOL.md). A Docker image running
the same Worker on `workerd` (Cloudflare's open-source runtime) is planned for v0.3, as are
alternative server implementations. Contributions welcome — the backend test suite in
`backend/cloudflare/test` is the conformance test.
