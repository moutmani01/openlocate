import { afterAll, beforeAll, describe, expect, it } from "vitest";
import { BackendError, Keyring, publishCards, rotateKey, sealLocation } from "@openlocate/client";
import { createIdentity, memberKeys, newEventId, newInvite, joinBinding, signRequest, verifyJoinBinding, deriveInvite } from "@openlocate/crypto";
import { toB64url, utf8 } from "@openlocate/protocol";
import { Inbox, device, invite, newGroupId, sleep, startBackend, type Device } from "./harness";

let url: string;
let dispose: () => Promise<void>;
beforeAll(async () => ({ url, dispose } = await startBackend()));
afterAll(() => dispose?.());

const DAY = 86_400_000;
const T0 = Math.floor(Date.now() / 1000);
const fix = (i = 0) => ({ ts: T0 + i, lat: 33.5731 + i * 1e-4, lon: -7.5898, acc: 10 });

async function status(p: Promise<unknown>): Promise<number> {
  try {
    await p;
    return 200;
  } catch (e) {
    if (e instanceof BackendError) return e.status;
    throw e;
  }
}

/** Alice creates a group; Bob and Carol join through invitations. */
async function family() {
  const alice = device(url, "Alice");
  const bob = device(url, "Bob");
  const carol = device(url, "Carol");
  const gid = newGroupId();
  await alice.api.createGroup(gid);
  await invite(alice, bob, gid);
  const state = await invite(alice, carol, gid);
  return { alice, bob, carol, gid, state };
}

async function share(from: Device, gid: string, to: Device[]) {
  from.sharing.shareWith = new Set(to.map((d) => d.id.deviceId));
  await publishCards(from.api, from.id, await from.api.getGroup(gid), from.sharing);
}

async function keyring(d: Device, gid: string): Promise<Keyring> {
  const k = new Keyring();
  await k.refresh(d.api, d.id, await d.api.getGroup(gid));
  return k;
}

describe("server info and routing", () => {
  it("reports protocol version and limits", async () => {
    const info = await device(url, "x").api.info();
    expect(info.protocol_version).toBe(1);
    expect(info.max_retention_ms).toBe(90 * DAY);
  });

  it("404s for a group that doesn't exist, without creating it", async () => {
    const d = device(url, "x");
    expect(await status(d.api.getGroup(newGroupId()))).toBe(404);
  });
});

describe("request authentication", () => {
  it("rejects unsigned, tampered, stale and replayed requests", async () => {
    const alice = device(url, "Alice");
    const gid = newGroupId();
    await alice.api.createGroup(gid);
    const path = `/v1/groups/${gid}`;

    expect((await fetch(url + path)).status).toBe(401);

    const stale = signRequest(alice.id, "GET", path, new Uint8Array(0), Date.now() - 5 * 60_000);
    expect((await fetch(url + path, { headers: stale })).status).toBe(401);

    const other = signRequest(alice.id, "GET", `/v1/groups/${newGroupId()}`);
    expect((await fetch(url + path, { headers: other })).status).toBe(401);

    const h = signRequest(alice.id, "GET", path);
    expect((await fetch(url + path, { headers: h })).status).toBe(200);
    const replay = await fetch(url + path, { headers: h });
    expect(replay.status).toBe(401);
    expect(await replay.json()).toEqual({ error: "replayed_request" });
  });

  it("rejects a body that doesn't match the signature", async () => {
    const alice = device(url, "Alice");
    const gid = newGroupId();
    await alice.api.createGroup(gid);
    const path = `/v1/groups/${gid}/events`;
    const h = signRequest(alice.id, "POST", path, utf8('{"events":[]}'));
    const res = await fetch(url + path, { method: "POST", headers: h, body: '{"events":[1]}' });
    expect(res.status).toBe(401);
  });

  it("refuses to create a group with someone else's keys", async () => {
    const alice = createIdentity();
    const mallory = device(url, "Mallory");
    const gid = newGroupId();
    const path = `/v1/groups/${gid}`;
    const body = utf8(JSON.stringify({ member: memberKeys(alice) }));
    const res = await fetch(url + path, { method: "PUT", headers: signRequest(mallory.id, "PUT", path, body), body });
    expect(res.status).toBe(400);
  });
});

describe("groups and invitations", () => {
  it("creates a group with the creator as admin", async () => {
    const alice = device(url, "Alice");
    const gid = newGroupId();
    const state = await alice.api.createGroup(gid);
    expect(state.members).toHaveLength(1);
    expect(state.members[0]).toMatchObject({ device_id: alice.id.deviceId, role: "admin" });
    expect(await status(alice.api.createGroup(gid))).toBe(409);
  });

  it("lets a joiner in once, with a binding only the inviter can verify", async () => {
    const alice = device(url, "Alice");
    const bob = device(url, "Bob");
    const eve = device(url, "Eve");
    const gid = newGroupId();
    await alice.api.createGroup(gid);

    const inv = newInvite();
    await alice.api.createInvitation(gid, { invite_id: inv.inviteId, auth_hash: inv.authHash, expires_at: Date.now() + 60_000 });
    const join = (d: Device) => {
      const keys = memberKeys(d.id);
      return d.api.joinGroup(gid, { invite_id: inv.inviteId, auth_key: toB64url(inv.authKey), member: keys, binding: joinBinding(inv, gid, keys) });
    };

    const state = await join(bob);
    const bobRecord = state.members.find((m) => m.device_id === bob.id.deviceId)!;
    expect(bobRecord.invited_by).toBe(alice.id.deviceId);
    // Alice, holding the invite secret from the QR code, confirms the server didn't swap Bob's keys.
    expect(verifyJoinBinding(deriveInvite(inv.secret), gid, bobRecord, bobRecord.binding!)).toBe(true);

    expect(await status(join(eve))).toBe(403); // single use
    expect(await status(eve.api.getGroup(gid))).toBe(403);
  });

  it("rejects a wrong secret, an expired invitation and a revoked one", async () => {
    const alice = device(url, "Alice");
    const bob = device(url, "Bob");
    const gid = newGroupId();
    await alice.api.createGroup(gid);
    const keys = memberKeys(bob.id);

    const inv = newInvite();
    await alice.api.createInvitation(gid, { invite_id: inv.inviteId, auth_hash: inv.authHash, expires_at: Date.now() + 60_000 });
    const wrong = newInvite();
    expect(await status(bob.api.joinGroup(gid, { invite_id: inv.inviteId, auth_key: toB64url(wrong.authKey), member: keys, binding: joinBinding(wrong, gid, keys) }))).toBe(403);

    const short = newInvite();
    await alice.api.createInvitation(gid, { invite_id: short.inviteId, auth_hash: short.authHash, expires_at: Date.now() + 500 });
    await sleep(700);
    expect(await status(bob.api.joinGroup(gid, { invite_id: short.inviteId, auth_key: toB64url(short.authKey), member: keys, binding: joinBinding(short, gid, keys) }))).toBe(403);

    await alice.api.revokeInvitation(gid, inv.inviteId);
    expect(await status(bob.api.joinGroup(gid, { invite_id: inv.inviteId, auth_key: toB64url(inv.authKey), member: keys, binding: joinBinding(inv, gid, keys) }))).toBe(403);
  });

  it("refuses invitations that live longer than 24 hours", async () => {
    const alice = device(url, "Alice");
    const gid = newGroupId();
    await alice.api.createGroup(gid);
    const inv = newInvite();
    expect(await status(alice.api.createInvitation(gid, { invite_id: inv.inviteId, auth_hash: inv.authHash, expires_at: Date.now() + 2 * DAY }))).toBe(400);
  });

  it("only admins remove others; the last member leaving erases the group", async () => {
    const { alice, bob, carol, gid } = await family();
    expect(await status(bob.api.removeMember(gid, carol.id.deviceId))).toBe(403);
    await alice.api.removeMember(gid, carol.id.deviceId);
    expect(await status(carol.api.getGroup(gid))).toBe(403);

    await alice.api.removeMember(gid, alice.id.deviceId); // admin leaves → Bob promoted
    const state = await bob.api.getGroup(gid);
    expect(state.members).toEqual([expect.objectContaining({ device_id: bob.id.deviceId, role: "admin" })]);

    await bob.api.removeMember(gid, bob.id.deviceId);
    expect(await status(bob.api.getGroup(gid))).toBe(404);
  });
});

describe("location sharing", () => {
  it("is per-person and not reciprocal", async () => {
    const { alice, bob, carol, gid } = await family();
    await share(alice, gid, [bob]); // Alice → Bob only
    await share(bob, gid, []); // Bob shares with nobody, but still tells people his name

    const state = await alice.api.getGroup(gid);
    expect(state.shares).toEqual([{ from: alice.id.deviceId, to: bob.id.deviceId }]);

    await alice.api.publishLocation(gid, [sealLocation(alice.id, gid, alice.sharing, fix(), DAY)]);

    const bobKeys = await keyring(bob, gid);
    expect(bobKeys.peers.get(alice.id.deviceId)).toEqual({ deviceId: alice.id.deviceId, displayName: "Alice", sharing: true });
    const bobSees = (await bob.api.getHistory(gid)).events;
    expect(bobSees).toHaveLength(1);
    expect(bobKeys.decrypt(gid, bobSees[0]!)).toMatchObject({ lat: 33.5731, lon: -7.5898 });

    // Carol is in the group but Alice doesn't share with her: no events, no key, only a name.
    const carolKeys = await keyring(carol, gid);
    expect(carolKeys.peers.get(alice.id.deviceId)?.sharing).toBe(false);
    expect((await carol.api.getHistory(gid)).events).toHaveLength(0);

    // Alice can see Bob's name, but not his location.
    const aliceKeys = await keyring(alice, gid);
    expect(aliceKeys.peers.get(bob.id.deviceId)).toMatchObject({ displayName: "Bob", sharing: false });
  });

  it("de-duplicates re-uploaded events and pages through an offline backlog", async () => {
    const { alice, bob, gid } = await family();
    await share(alice, gid, [bob]);

    // Offline: 30 fixes queued locally, then uploaded in two overlapping batches (oldest first).
    const queue = Array.from({ length: 30 }, (_, i) => sealLocation(alice.id, gid, alice.sharing, fix(i), DAY));
    expect(await alice.api.publishLocation(gid, queue.slice(0, 20))).toEqual({ accepted: 20, duplicates: 0, expired: 0 });
    expect(await alice.api.publishLocation(gid, queue.slice(10))).toEqual({ accepted: 10, duplicates: 10, expired: 0 });

    const keys = await keyring(bob, gid);
    const page1 = await bob.api.getHistory(gid, { limit: 25 });
    expect(page1.events).toHaveLength(25);
    expect(page1.more).toBe(true);
    const page2 = await bob.api.getHistory(gid, { after: page1.next_after, limit: 25 });
    expect(page2.events).toHaveLength(5);
    expect(page2.more).toBe(false);
    const points = [...page1.events, ...page2.events].map((e) => keys.decrypt(gid, e)!);
    expect(points.map((p) => p.ts)).toEqual(queue.map((_, i) => fix(i).ts));
  });

  it("refuses events published under another device's id", async () => {
    const { alice, bob, gid } = await family();
    const forged = { ...sealLocation(alice.id, gid, alice.sharing, fix(), DAY), event_id: newEventId(bob.id.deviceId) };
    expect(await status(alice.api.publishLocation(gid, [forged]))).toBe(400);
  });

  it("deletes history when it expires, and on request", async () => {
    const { alice, bob, gid } = await family();
    await share(alice, gid, [bob]);
    const now = Date.now();
    const soon = { ...sealLocation(alice.id, gid, alice.sharing, fix(), DAY), expires_at: now + 800 };
    const later = sealLocation(alice.id, gid, alice.sharing, fix(1), DAY);
    const past = { ...sealLocation(alice.id, gid, alice.sharing, fix(2), DAY), expires_at: now - 1 };
    expect(await alice.api.publishLocation(gid, [soon, later, past])).toEqual({ accepted: 2, duplicates: 0, expired: 1 });
    expect((await bob.api.getHistory(gid)).events).toHaveLength(2);

    await sleep(1200);
    const left = (await bob.api.getHistory(gid)).events;
    expect(left.map((e) => e.event_id)).toEqual([later.event_id]);

    await alice.api.deleteHistory(gid);
    expect((await bob.api.getHistory(gid)).events).toHaveLength(0);
  });

  it("never stores live-only events (retention: never)", async () => {
    const { alice, bob, gid } = await family();
    await share(alice, gid, [bob]);
    const live = sealLocation(alice.id, gid, alice.sharing, fix(), 0);
    expect(live.store).toBe(false);
    expect((await alice.api.publishLocation(gid, [live])).accepted).toBe(1);
    expect((await bob.api.getHistory(gid)).events).toHaveLength(0);
  });

  it("stop sharing: the viewer loses history access and future keys", async () => {
    const { alice, bob, gid } = await family();
    await share(alice, gid, [bob]);
    await alice.api.publishLocation(gid, [sealLocation(alice.id, gid, alice.sharing, fix(), DAY)]);
    const oldKeys = await keyring(bob, gid);

    alice.sharing = rotateKey(alice.sharing);
    await share(alice, gid, []);
    const next = sealLocation(alice.id, gid, alice.sharing, fix(1), DAY);
    await alice.api.publishLocation(gid, [next]);

    expect((await bob.api.getHistory(gid)).events).toHaveLength(0);
    expect(oldKeys.decrypt(gid, { ...next, device_id: alice.id.deviceId })).toBeNull();
  });

  it("removal + key rotation: a removed member can't read what comes next", async () => {
    const { alice, bob, carol, gid } = await family();
    await share(alice, gid, [bob, carol]);
    const carolKeys = await keyring(carol, gid);

    await alice.api.removeMember(gid, carol.id.deviceId);
    alice.sharing = rotateKey(alice.sharing);
    await share(alice, gid, [bob]);
    const next = sealLocation(alice.id, gid, alice.sharing, fix(), DAY);
    await alice.api.publishLocation(gid, [next]);

    expect(await status(carol.api.getHistory(gid))).toBe(403);
    // Even with a copy of the ciphertext (e.g. a leaked database), Carol's old key doesn't open it.
    expect(carolKeys.decrypt(gid, { ...next, device_id: alice.id.deviceId })).toBeNull();
    // Bob gets the new epoch key and reads it fine.
    const bobKeys = await keyring(bob, gid);
    const [e] = (await bob.api.getHistory(gid)).events;
    expect(bobKeys.decrypt(gid, e!)).toMatchObject({ lat: 33.5731 });
  });
});

describe("live connection", () => {
  it("relays encrypted events only to viewers, with presence and WebRTC signaling", async () => {
    const { alice, bob, carol, gid } = await family();
    await share(alice, gid, [bob]);
    const bobKeys = await keyring(bob, gid);

    const bobInbox = new Inbox();
    const carolInbox = new Inbox();
    const aliceInbox = new Inbox();
    const bobWs = await bob.api.subscribe(gid, bobInbox.push);
    const carolWs = await carol.api.subscribe(gid, carolInbox.push);
    await bobInbox.waitFor("hello");
    await carolInbox.waitFor("hello");
    const aliceWs = await alice.api.subscribe(gid, aliceInbox.push);
    expect((await aliceInbox.waitFor("hello")).online.sort()).toEqual(
      [alice.id.deviceId, bob.id.deviceId, carol.id.deviceId].sort(),
    );
    await bobInbox.waitFor("presence", (m) => m.device_id === alice.id.deviceId && m.online);

    // Publish over the persistent socket (no HTTP request per fix).
    const ev = sealLocation(alice.id, gid, alice.sharing, fix(), DAY);
    aliceWs.send({ type: "publish", events: [ev] });
    expect(await aliceInbox.waitFor("published")).toMatchObject({ accepted: 1 });
    const got = await bobInbox.waitFor("event");
    expect(bobKeys.decrypt(gid, got.event)).toMatchObject({ lat: 33.5731 });

    // WebRTC offer, forwarded verbatim to Bob only.
    aliceWs.send({ type: "signal", to: bob.id.deviceId, data: { sdp: "offer" } });
    expect(await bobInbox.waitFor("signal")).toEqual({ type: "signal", from: alice.id.deviceId, data: { sdp: "offer" } });

    aliceWs.send({ type: "ping" });
    await aliceInbox.waitFor("pong");

    await sleep(200);
    expect(carolInbox.messages.some((m) => m.type === "event" || m.type === "signal")).toBe(false);

    aliceWs.close();
    await bobInbox.waitFor("presence", (m) => m.device_id === alice.id.deviceId && !m.online);
    bobWs.close();
    carolWs.close();
  });

  it("rejects WebSocket connections from non-members", async () => {
    const { gid } = await family();
    const eve = device(url, "Eve");
    await expect(eve.api.subscribe(gid, () => {})).rejects.toThrow();
  });
});

describe("abuse limits", () => {
  it("rate-limits a flooding device", async () => {
    const alice = device(url, "Alice");
    const gid = newGroupId();
    await alice.api.createGroup(gid);
    const codes = await Promise.all(Array.from({ length: 90 }, () => status(alice.api.getGroup(gid))));
    expect(codes).toContain(429);
  });

  it("rejects oversized bodies before touching the group", async () => {
    const alice = device(url, "Alice");
    const gid = newGroupId();
    const path = `/v1/groups/${gid}/events`;
    const body = utf8("x".repeat(300 * 1024));
    // The Worker answers 413 from Content-Length without reading the body, so the runtime may
    // reset or stall the connection while the client is still uploading. Any of these is a rejection.
    const outcome = await fetch(url + path, {
      method: "POST",
      headers: signRequest(alice.id, "POST", path, body),
      body,
      signal: AbortSignal.timeout(5000),
    }).then(
      (r) => r.status,
      () => "connection reset",
    );
    expect([413, "connection reset"]).toContain(outcome);
  });
});
