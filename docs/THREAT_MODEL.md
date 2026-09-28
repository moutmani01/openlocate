# Threat model

**Assets:** current and historical locations; who knows whom (group membership); identity keys.
**Trust:** each person trusts their own phone and the people they chose to share with. The
server operator (including us, for the default instance) is trusted for *availability and
access control*, **not** for confidentiality.

## What the server can and cannot learn

| Visible to the server | Not visible |
|---|---|
| Device public keys and ids; group membership; who invited whom | Names (they're inside key cards) |
| Who currently shares with whom (from card metadata) | Location keys |
| When devices connect; number, size (padded) and epoch of events | Coordinates, accuracy, speed, heading, battery |
| Event expiry, rounded to the minute (≈ fix time + retention) | Exact fix time |
| IP addresses (inherent to any network service) | |

## Scenarios

**Attacker steals the server database.** Gets ciphertext, public keys and metadata above. No
readable locations: location keys only exist inside sealed boxes addressed to members' X25519
keys, which never leave phones. *Residual:* social graph and activity timing.

**Attacker steals an invitation (QR photo, forwarded link).** Invitations expire (default
10 min, max 24 h), are single-use, and can be revoked. If redeemed first by the attacker, the
real invitee's join fails visibly, and the attacker joins as a *new member with no access*:
sharing is per person and off by default, and every member is notified of joins.
*Mitigation to keep:* show the joiner's name + safety number on the inviter's phone before
they share.

**Malicious server adds a fake member or swaps keys.** The server can't forge the join binding
without `mac_key`, which never leaves the QR code, so the inviter's phone detects a substituted
key. Other members see a "joined" notice and can compare safety numbers. No location is sent
to anyone until a user explicitly turns on sharing with that person.
*Residual:* members who don't verify can be fooled into sharing with a server-injected
identity. Future: members co-sign the member list (transparency log / MLS-style).

**Malicious server replays or reorders data.** Request replay is rejected by nonce +
timestamp window. Event ciphertexts are bound (AEAD associated data) to group, sender, event id
and key epoch, so they can't be re-attributed. The server *can* replay an old event (clients
ignore already-seen event ids and show fix time from inside the ciphertext) or withhold events
(availability — out of scope).

**Attacker steals an unlocked phone.** Sees what the owner sees. Keys are in OS secure storage;
the local history DB is encrypted with a key held there. Remote response: another admin
removes the device from the group; sharers rotate keys automatically on removal.

**Attacker steals a locked phone.** Protected by OS full-disk encryption + Keystore/Keychain
(keys marked "after first unlock, this device only", not backed up).

**Malicious group member.** Sees only locations of people who chose to share with them.
Cannot publish as someone else (event ids are prefixed by the signed sender id; cards are
signed). Can screenshot/record what they're shown — inherent.

**Removed member.** Loses server access immediately (history, live relay, sockets closed). Any
sharer who had shared with them rotates their location key; new events are unreadable with
the old key (tested in `backend.test.ts`). They retain whatever they already saw.

**Network attacker.** TLS everywhere; plus request signatures and end-to-end encryption, so
even a TLS-intercepting proxy only sees ciphertext and can't forge requests.

**Abuse / resource exhaustion.** Per-device token bucket, 256 KiB body cap, batch ≤ 200, max 50
members, max 20 active invitations, per-device event cap (oldest dropped), server-side
retention cap. Unknown group ids don't allocate storage. *Future:* per-IP rate limiting at the
edge for group creation.

## Logging rules
Never log coordinates, payloads, card envelopes, keys, signatures or auth headers. The Worker
catches errors without logging request content, and `wrangler.toml` ships with observability
off. Operational logs, if enabled by an operator, must contain only status codes and timings.
