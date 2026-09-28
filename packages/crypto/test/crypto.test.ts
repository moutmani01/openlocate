import { beforeAll, describe, expect, it } from "vitest";
import {
  AUTH_HEADERS,
  deviceIdFromSignPk,
  fromB64url,
  requestSigningPayload,
  sha256,
  toB64url,
  utf8,
} from "@openlocate/protocol";
import {
  createIdentity,
  decodeInviteLink,
  decryptLocation,
  deriveInvite,
  encodeInviteLink,
  encryptLocation,
  exportIdentity,
  importIdentity,
  initCrypto,
  joinBinding,
  memberKeys,
  newEventId,
  newInvite,
  newLocationKey,
  openCard,
  safetyNumber,
  sealCard,
  signRequest,
  verifyJoinBinding,
  verifyMemberKeys,
  type CardContent,
  type EventContext,
} from "../src";

beforeAll(initCrypto);

const GROUP = "AAAAAAAAAAAAAAAAAAAAAA";

describe("identity", () => {
  it("derives the same device id as the server's WebCrypto code", async () => {
    const id = createIdentity();
    expect(id.deviceId).toHaveLength(22);
    expect(await deviceIdFromSignPk(id.signPk)).toBe(id.deviceId);
  });

  it("round-trips through secure-storage export", () => {
    const id = createIdentity();
    const back = importIdentity(exportIdentity(id));
    expect(back.deviceId).toBe(id.deviceId);
    expect(back.boxPk).toEqual(id.boxPk);
    expect(back.signPk).toEqual(id.signPk);
  });

  it("publishes verifiable member keys and rejects a swapped box key", () => {
    const a = createIdentity();
    const b = createIdentity();
    const keys = memberKeys(a);
    expect(verifyMemberKeys(keys)).toBe(true);
    expect(verifyMemberKeys({ ...keys, box_pk: toB64url(b.boxPk) })).toBe(false);
    expect(verifyMemberKeys({ ...keys, device_id: b.deviceId })).toBe(false);
  });

  it("gives stable, distinct safety numbers", () => {
    const a = createIdentity();
    expect(safetyNumber(a.signPk)).toMatch(/^(\d{5} ){11}\d{5}$/);
    expect(safetyNumber(a.signPk)).toBe(safetyNumber(a.signPk));
    expect(safetyNumber(a.signPk)).not.toBe(safetyNumber(createIdentity().signPk));
  });
});

describe("request signing", () => {
  it("produces a signature the server-side payload verifies", async () => {
    const id = createIdentity();
    const body = utf8('{"x":1}');
    const h = signRequest(id, "POST", "/v1/groups/x/events?a=1", body, 1_700_000_000_000);
    const payload = requestSigningPayload(
      "POST",
      "/v1/groups/x/events?a=1",
      1_700_000_000_000,
      h[AUTH_HEADERS.nonce]!,
      toB64url(await sha256(body)),
    );
    const key = await crypto.subtle.importKey("raw", id.signPk as Uint8Array<ArrayBuffer>, { name: "Ed25519" }, false, ["verify"]);
    const sig = fromB64url(h[AUTH_HEADERS.signature]!) as Uint8Array<ArrayBuffer>;
    expect(await crypto.subtle.verify({ name: "Ed25519" }, key, sig, payload as Uint8Array<ArrayBuffer>)).toBe(true);
    // A different body must not verify.
    const other = requestSigningPayload("POST", "/v1/groups/x/events?a=1", 1_700_000_000_000, h[AUTH_HEADERS.nonce]!, toB64url(await sha256(utf8("{}"))));
    expect(await crypto.subtle.verify({ name: "Ed25519" }, key, sig, other as Uint8Array<ArrayBuffer>)).toBe(false);
  });

  it("uses a fresh nonce every time", () => {
    const id = createIdentity();
    expect(signRequest(id, "GET", "/")[AUTH_HEADERS.nonce]).not.toBe(signRequest(id, "GET", "/")[AUTH_HEADERS.nonce]);
  });
});

describe("invitations", () => {
  it("derives the same material from the secret on both phones", () => {
    const inv = newInvite();
    const again = deriveInvite(inv.secret);
    expect(again.inviteId).toBe(inv.inviteId);
    expect(again.authHash).toBe(inv.authHash);
    expect(again.macKey).toEqual(inv.macKey);
    expect(inv.inviteId).toHaveLength(22);
  });

  it("binds the joiner's keys; a server-substituted key fails", () => {
    const inv = newInvite();
    const joiner = memberKeys(createIdentity());
    const impostor = memberKeys(createIdentity());
    const binding = joinBinding(inv, GROUP, joiner);
    expect(verifyJoinBinding(inv, GROUP, joiner, binding)).toBe(true);
    expect(verifyJoinBinding(inv, GROUP, impostor, binding)).toBe(false);
    expect(verifyJoinBinding(newInvite(), GROUP, joiner, binding)).toBe(false);
  });

  it("round-trips an invite link and refuses plain-http backends", () => {
    const inv = newInvite();
    const link = encodeInviteLink({
      backend: "https://openlocate.example.org",
      groupId: GROUP,
      secret: inv.secret,
      inviter: "BBBBBBBBBBBBBBBBBBBBBB",
      expiresAt: 123,
      name: "Family & friends",
    });
    const back = decodeInviteLink(link);
    expect(back.secret).toEqual(inv.secret);
    expect(back.name).toBe("Family & friends");
    expect(back.backend).toBe("https://openlocate.example.org");
    expect(() => decodeInviteLink(link.replace("https%3A", "http%3A"))).toThrow(/https/);
  });
});

describe("key cards", () => {
  const card = (from: string, to: string, extra: Partial<CardContent> = {}): CardContent => ({
    v: 1,
    group_id: GROUP,
    from,
    to,
    epoch: 1,
    issued_at: 1,
    display_name: "Alice",
    ...extra,
  });

  it("opens for the recipient only", () => {
    const a = createIdentity();
    const b = createIdentity();
    const c = createIdentity();
    const key = toB64url(newLocationKey());
    const env = sealCard(a, memberKeys(b), card(a.deviceId, b.deviceId, { location_key: key }));
    expect(openCard(b, memberKeys(a), GROUP, env).location_key).toBe(key);
    expect(() => openCard(c, memberKeys(a), GROUP, env)).toThrow();
  });

  it("rejects a card re-signed by someone else or moved to another group", () => {
    const a = createIdentity();
    const b = createIdentity();
    const mallory = createIdentity();
    const env = sealCard(a, memberKeys(b), card(a.deviceId, b.deviceId));
    expect(() => openCard(b, memberKeys(mallory), GROUP, env)).toThrow(/signature/);
    expect(() => openCard(b, memberKeys(a), "CCCCCCCCCCCCCCCCCCCCCC", env)).toThrow(/signature/);
  });
});

describe("location encryption", () => {
  const point = { ts: 1_789_320_000, lat: 33.5731104, lon: -7.5898434, acc: 12, spd: 4.2, hdg: 120 };
  const ctx = (): EventContext => {
    const deviceId = "DDDDDDDDDDDDDDDDDDDDDD";
    return { groupId: GROUP, deviceId, eventId: newEventId(deviceId), epoch: 3 };
  };

  it("round-trips and rounds coordinates to ~10 cm", () => {
    const key = newLocationKey();
    const c = ctx();
    const p = decryptLocation(key, c, encryptLocation(key, c, point));
    expect(p).toEqual({ ts: 1_789_320_000, lat: 33.57311, lon: -7.589843, acc: 12, spd: 4.2, hdg: 120 });
  });

  it("fails with a rotated key (revoked member keeps only the old one)", () => {
    const oldKey = newLocationKey();
    const newKey = newLocationKey();
    const c = ctx();
    const payload = encryptLocation(newKey, { ...c, epoch: 4 }, point);
    expect(() => decryptLocation(oldKey, { ...c, epoch: 4 }, payload)).toThrow();
  });

  it("detects a ciphertext moved to another event, sender or epoch", () => {
    const key = newLocationKey();
    const c = ctx();
    const payload = encryptLocation(key, c, point);
    expect(() => decryptLocation(key, { ...c, eventId: newEventId(c.deviceId) }, payload)).toThrow();
    expect(() => decryptLocation(key, { ...c, deviceId: "EEEEEEEEEEEEEEEEEEEEEE" }, payload)).toThrow();
    expect(() => decryptLocation(key, { ...c, epoch: 2 }, payload)).toThrow();
  });

  it("detects tampering", () => {
    const key = newLocationKey();
    const c = ctx();
    const raw = fromB64url(encryptLocation(key, c, point));
    raw[raw.length - 1]! ^= 1;
    expect(() => decryptLocation(key, c, toB64url(raw))).toThrow();
  });

  it("pads so optional fields don't change the ciphertext length", () => {
    const key = newLocationKey();
    const c = ctx();
    const minimal = encryptLocation(key, c, { ts: 1, lat: 1, lon: 1 });
    const full = encryptLocation(key, c, { ts: 1, lat: 1, lon: 1, acc: 5, spd: 1, hdg: 90, bat: 50 });
    expect(minimal.length).toBe(full.length);
  });
});
