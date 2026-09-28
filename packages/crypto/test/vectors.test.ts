import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { beforeAll, expect, it } from "vitest";
import { AUTH_HEADERS, fromB64url, requestSigningPayload, sha256, toB64url, utf8 } from "@openlocate/protocol";
import {
  decryptLocation,
  deriveInvite,
  encryptLocation,
  identityFromSeeds,
  initCrypto,
  joinBinding,
  memberKeys,
  openCard,
  safetyNumber,
  sealCard,
  signRequest,
} from "../src";

/**
 * Cross-implementation test vectors. The Dart port (apps/mobile/test/crypto_test.dart) checks
 * itself against this file. Regenerate with: UPDATE_VECTORS=1 npx vitest run packages/crypto
 */
const FILE = fileURLToPath(new URL("./vectors.json", import.meta.url));
const bytes = (start: number, n = 32) => Uint8Array.from({ length: n }, (_, i) => (start + i) & 0xff);

beforeAll(initCrypto);

/** Everything here is deterministic, so it must reproduce exactly. */
async function deterministicVectors() {
  const alice = identityFromSeeds(bytes(1), bytes(33));
  const bob = identityFromSeeds(bytes(65), bytes(97));
  const groupId = "R3JvdXBHcm91cEdyb3VwMQ";
  const inv = deriveInvite(bytes(129));
  const bobKeys = memberKeys(bob);

  const method = "POST";
  const target = `/v1/groups/${groupId}/events?x=1`;
  const timestamp = 1_789_320_000_000;
  const body = '{"events":[]}';
  const nonce = toB64url(bytes(180, 16));
  const bodySha256 = toB64url(await sha256(utf8(body)));
  const headers = signRequest(alice, method, target, utf8(body), timestamp, nonce);

  const locationKey = bytes(161);
  const ctx = { groupId, deviceId: alice.deviceId, eventId: `${alice.deviceId}:AAAAAAAAAAAAAAAAAAAAAA`, epoch: 7 };
  const point = { ts: 1_789_320_000, lat: 33.57311, lon: -7.589843, acc: 12, spd: 4.2, hdg: 120 };
  const aeadNonce = bytes(200, 24);

  return {
    identities: { alice, bob },
    vectors: {
      group_id: groupId,
      alice: { sign_seed: toB64url(bytes(1)), box_seed: toB64url(bytes(33)), keys: memberKeys(alice), safety_number: safetyNumber(alice.signPk) },
      bob: { sign_seed: toB64url(bytes(65)), box_seed: toB64url(bytes(97)), keys: bobKeys },
      request: {
        method,
        target,
        timestamp,
        body,
        nonce,
        body_sha256: bodySha256,
        payload: new TextDecoder().decode(requestSigningPayload(method, target, timestamp, nonce, bodySha256)),
        signature: headers[AUTH_HEADERS.signature]!,
      },
      invite: {
        secret: toB64url(inv.secret),
        invite_id: inv.inviteId,
        auth_key: toB64url(inv.authKey),
        auth_hash: inv.authHash,
        mac_key: toB64url(inv.macKey),
        bob_binding: joinBinding(inv, groupId, bobKeys),
      },
      location: {
        key: toB64url(locationKey),
        group_id: groupId,
        device_id: ctx.deviceId,
        event_id: ctx.eventId,
        epoch: ctx.epoch,
        nonce: toB64url(aeadNonce),
        point,
        payload: encryptLocation(locationKey, ctx, point, aeadNonce),
      },
    },
  };
}

it("reproduces the committed cross-implementation vectors", async () => {
  const { identities, vectors } = await deterministicVectors();

  if (process.env.UPDATE_VECTORS || !existsSync(FILE)) {
    // Sealed boxes are randomized, so the card is generated once and verified by opening it.
    const envelope = sealCard(identities.alice, vectors.bob.keys, {
      v: 1,
      group_id: vectors.group_id,
      from: identities.alice.deviceId,
      to: identities.bob.deviceId,
      epoch: 7,
      issued_at: 1_789_320_000_000,
      display_name: "Alice ☀",
      location_key: vectors.location.key,
    });
    writeFileSync(FILE, JSON.stringify({ ...vectors, card: { envelope } }, null, 2) + "\n");
  }

  const { card, ...saved } = JSON.parse(readFileSync(FILE, "utf8"));
  expect(saved).toEqual(vectors);

  const opened = openCard(identities.bob, vectors.alice.keys, vectors.group_id, card.envelope);
  expect(opened.display_name).toBe("Alice ☀");
  expect(opened.location_key).toBe(vectors.location.key);
  const l = vectors.location;
  expect(
    decryptLocation(fromB64url(l.key), { groupId: l.group_id, deviceId: l.device_id, eventId: l.event_id, epoch: l.epoch }, l.payload),
  ).toEqual(l.point);
});
