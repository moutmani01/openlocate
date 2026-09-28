# Security policy

## Reporting a vulnerability
Please **do not** open a public issue. Use GitHub's *Report a vulnerability* (private security
advisory) on this repository. Include steps to reproduce and the impact you expect. We aim to
acknowledge within 72 hours and to agree on a disclosure date with you.

## Scope
In scope: the protocol, crypto, backend, and apps in this repository — especially anything
that lets a server, network attacker or non-authorised member read locations, impersonate a
device, join without a valid invitation, or keep access after removal.

## Design references
- [Threat model](docs/THREAT_MODEL.md)
- [Protocol](docs/PROTOCOL.md)

## Rules for contributors
- Use libsodium primitives through `packages/crypto` (and its Dart counterpart). No custom
  cryptography.
- Never log coordinates, payloads, keys, signatures, tokens or auth headers.
- No analytics, advertising or tracking SDKs.
- Changes to crypto or the protocol need tests and a note in the decision log
  ([ARCHITECTURE.md](docs/ARCHITECTURE.md#decision-log)).
