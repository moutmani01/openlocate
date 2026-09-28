# OpenLocate protocol v1

`protocol_version: 1`. Any server implementing this document works with every OpenLocate
client. Types are in `packages/protocol/src/types.ts`; the Cloudflare backend and its tests
(`backend/cloudflare/test`) are the reference.

Conventions: JSON bodies; all binary values are **unpadded base64url**; times are **Unix
milliseconds** unless stated; ids (`device_id`, `group_id`, `invite_id`) are 16 bytes → 22 chars.

## Request authentication

Every group request is signed by the device's Ed25519 key.

| Header | Value |
|---|---|
| `x-ol-device` | Ed25519 public key (32 bytes) |
| `x-ol-timestamp` | Unix ms; must be within ±60 s of server time |
| `x-ol-nonce` | 16 random bytes, never reused |
| `x-ol-signature` | Ed25519 signature (64 bytes) over the payload below |

```
payload = "OL1-REQ\n" + METHOD + "\n" + path_and_query + "\n" + timestamp + "\n" + nonce + "\n" + b64url(SHA-256(body))
```

The server derives `device_id = b64url(SHA-256(pk)[0..16])`. Servers must reject a
`(device, nonce)` pair seen before within the timestamp window (replay protection).
WebSocket upgrades carry the same four fields as query parameters `device`, `ts`, `nonce`,
`sig`, signing `GET` + the bare path + the hash of an empty body.

## Endpoints

| Method & path | Who | Body → Response |
|---|---|---|
| `GET /v1/info` | anyone | → `ServerInfo` |
| `PUT /v1/groups/{gid}` | anyone | `{member: MemberKeys}` → `201 GroupState` (creator becomes admin) · `409` if it exists |
| `GET /v1/groups/{gid}` | member | → `GroupState` |
| `POST /v1/groups/{gid}/invitations` | member | `{invite_id, auth_hash, expires_at}` (≤ 24 h) → `201` |
| `DELETE /v1/groups/{gid}/invitations/{iid}` | creator of invite or admin | → `204` |
| `POST /v1/groups/{gid}/join` | invitee | `{invite_id, auth_key, member, binding}` → `GroupState` · `403 invalid_invitation` for unknown/used/expired/wrong secret alike |
| `DELETE /v1/groups/{gid}/members/{did}` | self, or admin | → `204`. Deletes the member's cards and stored events. Last member leaving deletes the group. |
| `PUT /v1/groups/{gid}/cards/{to}` | member | `{envelope: {sealed, sig}, epoch, shares_location}` → `204` |
| `GET /v1/groups/{gid}/cards` | member | → `{cards: CardRecord[]}` addressed to the caller |
| `POST /v1/groups/{gid}/events` | member | `{events: LocationEvent[]}` (1–200) → `{accepted, duplicates, expired}` |
| `GET /v1/groups/{gid}/events?after=&from=&limit=` | member | → `{events: StoredEvent[], next_after, more}` — own events + those of members currently sharing with the caller |
| `DELETE /v1/groups/{gid}/events[?expires_before=]` | member | → `204`, deletes caller's own events |
| `GET /v1/groups/{gid}/ws` (upgrade) | member | WebSocket, below |

Errors are `{"error": "<code>"}` with an HTTP status. `401` auth, `403` membership/permission,
`404` unknown group/resource, `409` conflict, `413` body > 256 KiB, `429` rate limited.

`MemberKeys = {device_id, sign_pk, box_pk, box_sig}` where
`box_sig = Ed25519(sign_sk, "OL1-BOXKEY\n" ‖ box_pk)`. The server verifies it, and that the
record matches the signing key of the request that submits it.

`LocationEvent = {event_id, epoch, payload, expires_at, store?}`:
- `event_id` must be `<caller device_id>:<22 chars>`; duplicates are ignored and counted.
- `store: false` → relayed live only, never persisted.
- `expires_at` ≤ now → dropped (`expired`); otherwise clamped to the server's max retention.

## WebSocket messages

Client → server: `{type:"publish", events}` · `{type:"signal", to, data}` · `{type:"ping"}`

Server → client:
`hello {device_id, online[]}` · `event {event: {device_id, event_id, epoch, payload, seq|null}}`
· `published {accepted, duplicates, expired}` · `signal {from, data}` ·
`presence {device_id, online}` · `member_joined` · `member_left` · `card_updated {from}` ·
`pong` · `error {error}`

`event` goes only to devices the sender currently shares with, carrying the newest event of
each publish. `signal` is forwarded verbatim to one member (WebRTC offer/answer/ICE).

## End-to-end formats (opaque to servers)

**Invitation link:** `openlocate://invite?b=<backend origin>&g=<group>&s=<secret>&i=<inviter id>&e=<expires ms>[&n=<name>]`.
From the 32-byte secret, with libsodium `crypto_kdf_derive_from_key(ctx="OLinvite")`:
subkey 1 (32 B) = `auth_key`, subkey 2 (32 B) = `mac_key`, subkey 3 (16 B) = `invite_id`.
`auth_hash = SHA-256(auth_key)`. `binding = HMAC-SHA-256(mac_key, "OL1-JOIN\n" + group + "\n" + sign_pk + "\n" + box_pk)`.

**Key card:** `sealed = crypto_box_seal(JSON(CardContent), recipient.box_pk)`,
`sig = Ed25519(sender.sign_sk, "OL1-CARD\n" + group + "\n" + to + "\n" ‖ sealed)`.
`CardContent = {v:1, group_id, from, to, epoch, issued_at, display_name, location_key?}`.
Receivers verify `sig`, open, and check `group_id/from/to` match.

**Location payload:** `nonce(24) ‖ XChaCha20-Poly1305-IETF(key, nonce, pad64(JSON(point)),
AAD = "OL1-LOC\n" + group + "\n" + device + "\n" + event_id + "\n" + epoch)`, where `pad64` is
libsodium ISO/IEC 7816-4 padding to a 64-byte block.

## Versioning
New optional fields may be added within v1; clients and servers ignore unknown fields.
Incompatible changes get `/v2/` paths and a new `protocol_version`; servers keep v1 for at
least one release cycle. Clients never depend on a server's storage schema.
