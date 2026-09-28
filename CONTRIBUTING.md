# Contributing

Thanks for helping! OpenLocate optimises for **privacy, reliability, battery life and
simplicity** — in that order — over features.

## Setup
```bash
npm install
npm test
npm run typecheck
```
Mobile (once `apps/mobile` lands): Flutter stable, Android Studio / Xcode.

## Guidelines
- Small pull requests, one concern each. Keep `main` buildable and tests green.
- New behaviour comes with tests. Backend changes need an end-to-end test in
  `backend/cloudflare/test`; crypto changes need unit tests in `packages/crypto/test`.
- Protocol changes: update [docs/PROTOCOL.md](docs/PROTOCOL.md) and `packages/protocol`
  together, keep v1 backwards-compatible, and add an entry to the decision log.
- No proprietary dependencies without discussion in an issue first. No analytics/ads/trackers.
- Never log location data, keys or tokens (see [SECURITY.md](SECURITY.md)).
- Match the surrounding code style; TypeScript is strict.

## Commits
Imperative subject line ("Add history paging"), explaining *why* in the body when it isn't
obvious.

## Code of conduct
See [CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md).

## License
By contributing you agree your contributions are licensed under Apache-2.0.
