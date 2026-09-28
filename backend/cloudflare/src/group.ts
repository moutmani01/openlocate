import { DurableObject } from "cloudflare:workers";
import {
  LIMITS,
  PROTOCOL_VERSION,
  fromB64url,
  isB64url,
  isB64urlBytes,
  isEventIdFor,
  isId,
  isInt,
  sha256,
  toB64url,
  type GroupState,
  type Member,
  type PublishResponse,
  type RelayedEvent,
  type ServerMessage,
  type StoredEvent,
} from "@openlocate/protocol";
import { validMemberKeys, type Verified } from "./auth";
import { INTERNAL, maxRetentionMs, type Env } from "./env";
import { error, json, noContent, readJson } from "./http";

const SCHEMA = `
CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);
CREATE TABLE IF NOT EXISTS members (
  device_id TEXT PRIMARY KEY, sign_pk TEXT NOT NULL, box_pk TEXT NOT NULL, box_sig TEXT NOT NULL,
  role TEXT NOT NULL, invited_by TEXT, binding TEXT, joined_at INTEGER NOT NULL
);
CREATE TABLE IF NOT EXISTS invitations (
  invite_id TEXT PRIMARY KEY, created_by TEXT NOT NULL, auth_hash TEXT NOT NULL,
  expires_at INTEGER NOT NULL, used_at INTEGER, used_by TEXT
);
CREATE TABLE IF NOT EXISTS cards (
  from_id TEXT NOT NULL, to_id TEXT NOT NULL, sealed TEXT NOT NULL, sig TEXT NOT NULL,
  epoch INTEGER NOT NULL, shares INTEGER NOT NULL, updated_at INTEGER NOT NULL,
  PRIMARY KEY (from_id, to_id)
);
CREATE TABLE IF NOT EXISTS events (
  seq INTEGER PRIMARY KEY AUTOINCREMENT, device_id TEXT NOT NULL, event_id TEXT NOT NULL UNIQUE,
  epoch INTEGER NOT NULL, payload TEXT NOT NULL, expires_at INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS events_by_expiry ON events (expires_at);
CREATE INDEX IF NOT EXISTS events_by_device ON events (device_id, seq);
CREATE TABLE IF NOT EXISTS nonces (nonce TEXT PRIMARY KEY, expires_at INTEGER NOT NULL);
CREATE INDEX IF NOT EXISTS nonces_by_expiry ON nonces (expires_at);
`;

/** Token bucket per device: bursts of 60 requests/messages, refilling at 5 per second. */
const RATE = { capacity: 60, perSecond: 5 };

type Row = Record<string, SqlStorageValue>;

/**
 * One instance per group. Holds membership, invitations, key cards (opaque), encrypted location
 * events, and the group's live WebSocket connections (hibernatable, so idle groups cost nothing).
 * It never sees a readable location, name, or key.
 */
export class GroupDurableObject extends DurableObject<Env> {
  private readonly sql: SqlStorage;
  private readonly buckets = new Map<string, { tokens: number; at: number }>();

  constructor(ctx: DurableObjectState, env: Env) {
    super(ctx, env);
    this.sql = ctx.storage.sql;
    ctx.setWebSocketAutoResponse(new WebSocketRequestResponsePair('{"type":"ping"}', '{"type":"pong"}'));
  }

  // ---------------------------------------------------------------- HTTP

  override async fetch(req: Request): Promise<Response> {
    const h = (k: string) => req.headers.get(k) ?? "";
    const auth: Verified = {
      deviceId: h(INTERNAL.device),
      signPk: h(INTERNAL.signPk),
      nonce: h(INTERNAL.nonce),
      timestamp: Number(h(INTERNAL.timestamp)),
    };
    const groupId = h(INTERNAL.group);
    const url = new URL(req.url);
    const seg = url.pathname.split("/").filter(Boolean);
    const now = Date.now();
    const route = `${req.method} ${seg[0] ?? ""}${seg.length > 1 ? "/:id" : ""}`;

    // Creation is idempotent-by-conflict (a replay just gets 409), so it needs no nonce.
    if (route === "PUT ") return this.create(req, auth, groupId, now);
    // Read-only check: an unknown group id must not cause any storage to be written.
    if (!this.initialized()) return error(404, "group_not_found");

    const me = this.member(auth.deviceId);
    // Joining is the only thing a non-member may do; invitations are single-use, so no nonce needed.
    if (route === "POST join") return this.join(req, auth, now);
    if (!me) return error(403, "not_a_member");
    if (!this.consumeNonce(auth, now)) return error(401, "replayed_request");
    if (!this.allow(me.device_id, now)) return error(429, "rate_limited");

    switch (route) {
      case "GET ":
        return json(this.state());
      case "POST invitations":
        return this.createInvitation(req, me, now);
      case "DELETE invitations/:id":
        return this.revokeInvitation(me, seg[1]!);
      case "DELETE members/:id":
        return this.removeMember(me, seg[1]!);
      case "PUT cards/:id":
        return this.putCard(req, me, seg[1]!, now);
      case "GET cards":
        return this.getCards(me);
      case "POST events": {
        const body = await readJson(req);
        const r = await this.publish(me.device_id, body?.events, now);
        return typeof r === "string" ? error(400, r) : json(r);
      }
      case "GET events":
        return this.history(me, url, now);
      case "DELETE events":
        return this.deleteHistory(me, url);
      case "GET ws":
        return this.openSocket(me);
      default:
        return error(404, "not_found");
    }
  }

  private async create(req: Request, auth: Verified, groupId: string, now: number): Promise<Response> {
    if (this.initialized()) return error(409, "group_exists");
    const body = await readJson(req);
    if (!(await validMemberKeys(body?.member, auth))) return error(400, "invalid_member");
    if (this.initialized()) return error(409, "group_exists"); // re-check after the await
    const m = body!.member as Member;
    this.sql.exec(SCHEMA);
    this.sql.exec("INSERT INTO meta (key, value) VALUES ('schema', '1'), ('group_id', ?), ('created_at', ?)", groupId, String(now));
    this.sql.exec(
      "INSERT INTO members (device_id, sign_pk, box_pk, box_sig, role, invited_by, binding, joined_at) VALUES (?, ?, ?, ?, 'admin', NULL, NULL, ?)",
      m.device_id, m.sign_pk, m.box_pk, m.box_sig, now,
    );
    return json(this.state(), 201);
  }

  private async join(req: Request, auth: Verified, now: number): Promise<Response> {
    const b = await readJson(req);
    if (!b || !isId(b.invite_id) || !isB64urlBytes(b.auth_key, 32) || !isB64urlBytes(b.binding, 32)) {
      return error(400, "invalid_request");
    }
    if (!(await validMemberKeys(b.member, auth))) return error(400, "invalid_member");
    const authHash = toB64url(await sha256(fromB64url(b.auth_key)));

    // No awaits from here on: check-and-consume the invitation atomically.
    if (this.member(auth.deviceId)) return error(409, "already_member");
    const inv = this.sql.exec("SELECT * FROM invitations WHERE invite_id = ?", b.invite_id).toArray()[0];
    // One error for unknown, used, expired and wrong-secret, so probing reveals nothing.
    if (!inv || inv.used_at !== null || (inv.expires_at as number) <= now || inv.auth_hash !== authHash) {
      return error(403, "invalid_invitation");
    }
    if (this.memberCount() >= LIMITS.maxMembers) return error(403, "group_full");
    const m = b.member as Member;
    this.sql.exec(
      "INSERT INTO members (device_id, sign_pk, box_pk, box_sig, role, invited_by, binding, joined_at) VALUES (?, ?, ?, ?, 'member', ?, ?, ?)",
      m.device_id, m.sign_pk, m.box_pk, m.box_sig, inv.created_by, b.binding, now,
    );
    this.sql.exec("UPDATE invitations SET used_at = ?, used_by = ? WHERE invite_id = ?", now, m.device_id, b.invite_id);
    this.broadcast({ type: "member_joined", device_id: m.device_id });
    return json(this.state());
  }

  private async createInvitation(req: Request, me: Member, now: number): Promise<Response> {
    const b = await readJson(req);
    if (
      !b || !isId(b.invite_id) || !isB64urlBytes(b.auth_hash, 32) ||
      !isInt(b.expires_at, now + 1, now + LIMITS.maxInviteTtlMs)
    ) {
      return error(400, "invalid_request");
    }
    this.sql.exec("DELETE FROM invitations WHERE expires_at < ?", now - 86_400_000);
    const active = this.sql.exec("SELECT COUNT(*) AS n FROM invitations WHERE used_at IS NULL AND expires_at > ?", now).one().n as number;
    if (active >= LIMITS.maxActiveInvitations) return error(429, "too_many_invitations");
    if (this.sql.exec("SELECT 1 FROM invitations WHERE invite_id = ?", b.invite_id).toArray().length) {
      return error(409, "invitation_exists");
    }
    this.sql.exec(
      "INSERT INTO invitations (invite_id, created_by, auth_hash, expires_at) VALUES (?, ?, ?, ?)",
      b.invite_id, me.device_id, b.auth_hash, b.expires_at,
    );
    return json({ invite_id: b.invite_id }, 201);
  }

  private revokeInvitation(me: Member, inviteId: string): Response {
    const inv = this.sql.exec("SELECT created_by FROM invitations WHERE invite_id = ?", inviteId).toArray()[0];
    if (!inv) return error(404, "not_found");
    if (inv.created_by !== me.device_id && me.role !== "admin") return error(403, "forbidden");
    this.sql.exec("DELETE FROM invitations WHERE invite_id = ?", inviteId);
    return noContent();
  }

  private async removeMember(me: Member, target: string): Promise<Response> {
    if (!this.member(target)) return error(404, "not_found");
    if (target !== me.device_id && me.role !== "admin") return error(403, "forbidden");

    this.sql.exec("DELETE FROM members WHERE device_id = ?", target);
    this.sql.exec("DELETE FROM cards WHERE from_id = ? OR to_id = ?", target, target);
    this.sql.exec("DELETE FROM events WHERE device_id = ?", target);
    this.sql.exec("DELETE FROM invitations WHERE created_by = ? AND used_at IS NULL", target);
    for (const ws of this.ctx.getWebSockets(target)) ws.close(4001, "removed");

    if (this.memberCount() === 0) {
      // Last one out: erase the group entirely.
      for (const ws of this.ctx.getWebSockets()) ws.close(4001, "group_deleted");
      await this.ctx.storage.deleteAlarm();
      await this.ctx.storage.deleteAll();
      return noContent();
    }
    if (!this.sql.exec("SELECT 1 FROM members WHERE role = 'admin'").toArray().length) {
      this.sql.exec(
        "UPDATE members SET role = 'admin' WHERE device_id = (SELECT device_id FROM members ORDER BY joined_at, device_id LIMIT 1)",
      );
    }
    this.broadcast({ type: "member_left", device_id: target });
    return noContent();
  }

  private async putCard(req: Request, me: Member, to: string, now: number): Promise<Response> {
    if (!isId(to) || to === me.device_id) return error(400, "invalid_recipient");
    const b = await readJson(req);
    const env = b?.envelope as Record<string, unknown> | undefined;
    if (
      !b || !env || !isB64url(env.sealed, LIMITS.maxEnvelopeChars) || !isB64urlBytes(env.sig, 64) ||
      !isInt(b.epoch) || typeof b.shares_location !== "boolean"
    ) {
      return error(400, "invalid_request");
    }
    if (!this.member(to)) return error(404, "not_found");
    this.sql.exec(
      `INSERT INTO cards (from_id, to_id, sealed, sig, epoch, shares, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?)
       ON CONFLICT (from_id, to_id) DO UPDATE SET sealed = excluded.sealed, sig = excluded.sig,
         epoch = excluded.epoch, shares = excluded.shares, updated_at = excluded.updated_at`,
      me.device_id, to, env.sealed, env.sig, b.epoch, b.shares_location ? 1 : 0, now,
    );
    this.sendTo(to, { type: "card_updated", from: me.device_id });
    return noContent();
  }

  private getCards(me: Member): Response {
    const cards = this.sql
      .exec("SELECT * FROM cards WHERE to_id = ?", me.device_id)
      .toArray()
      .map((r) => ({
        from: r.from_id,
        to: r.to_id,
        envelope: { sealed: r.sealed, sig: r.sig },
        epoch: r.epoch,
        shares_location: r.shares === 1,
        updated_at: r.updated_at,
      }));
    return json({ cards });
  }

  private history(me: Member, url: URL, now: number): Response {
    const after = Number(url.searchParams.get("after") ?? 0);
    const limit = Math.min(Number(url.searchParams.get("limit") ?? LIMITS.historyPageSize), LIMITS.historyPageSize);
    const from = url.searchParams.get("from");
    if (!isInt(after) || !isInt(limit, 1) || (from !== null && !isId(from))) return error(400, "invalid_request");

    // Visible: your own events, plus those of everyone currently sharing with you.
    const visible = [me.device_id, ...this.sharersTo(me.device_id)];
    const ids = from === null ? visible : visible.filter((d) => d === from);
    if (!ids.length) return json({ events: [], next_after: after, more: false });

    const rows = this.sql
      .exec(
        `SELECT seq, device_id, event_id, epoch, payload, expires_at FROM events
         WHERE seq > ? AND expires_at > ? AND device_id IN (${ids.map(() => "?").join(",")})
         ORDER BY seq LIMIT ?`,
        after, now, ...ids, limit + 1,
      )
      .toArray() as unknown as StoredEvent[];
    const more = rows.length > limit;
    const events = more ? rows.slice(0, limit) : rows;
    return json({ events, next_after: events.at(-1)?.seq ?? after, more });
  }

  private deleteHistory(me: Member, url: URL): Response {
    const before = url.searchParams.get("expires_before");
    if (before === null) {
      this.sql.exec("DELETE FROM events WHERE device_id = ?", me.device_id);
    } else {
      if (!isInt(Number(before))) return error(400, "invalid_request");
      this.sql.exec("DELETE FROM events WHERE device_id = ? AND expires_at < ?", me.device_id, Number(before));
    }
    return noContent();
  }

  // ---------------------------------------------------------------- events

  /** Validate, de-duplicate, store and relay a batch. Returns an error code string on rejection. */
  private async publish(device: string, events: unknown, now: number): Promise<PublishResponse | string> {
    if (!Array.isArray(events) || events.length === 0 || events.length > LIMITS.maxBatch) return "invalid_batch";
    for (const e of events as Record<string, unknown>[]) {
      if (
        typeof e !== "object" || e === null || !isEventIdFor(e.event_id, device) || !isInt(e.epoch) ||
        !isB64url(e.payload, LIMITS.maxPayloadChars) || !isInt(e.expires_at) ||
        (e.store !== undefined && typeof e.store !== "boolean")
      ) {
        return "invalid_event";
      }
    }

    const cap = now + maxRetentionMs(this.env);
    const res: PublishResponse = { accepted: 0, duplicates: 0, expired: 0 };
    let latest: RelayedEvent | null = null;
    let earliestExpiry = Infinity;
    for (const e of events as { event_id: string; epoch: number; payload: string; expires_at: number; store?: boolean }[]) {
      const base = { device_id: device, event_id: e.event_id, epoch: e.epoch, payload: e.payload };
      if (e.store === false) {
        res.accepted++;
        latest = { ...base, seq: null };
        continue;
      }
      if (e.expires_at <= now) {
        res.expired++;
        continue;
      }
      const expires = Math.min(e.expires_at, cap);
      const row = this.sql
        .exec(
          `INSERT INTO events (device_id, event_id, epoch, payload, expires_at) VALUES (?, ?, ?, ?, ?)
           ON CONFLICT (event_id) DO NOTHING RETURNING seq`,
          device, e.event_id, e.epoch, e.payload, expires,
        )
        .toArray()[0];
      if (!row) {
        res.duplicates++;
        continue;
      }
      res.accepted++;
      earliestExpiry = Math.min(earliestExpiry, expires);
      latest = { ...base, seq: row.seq as number };
    }

    if (earliestExpiry !== Infinity) {
      // Cap per-device storage by dropping the oldest events.
      this.sql.exec(
        `DELETE FROM events WHERE device_id = ? AND seq <= (
           SELECT seq FROM events WHERE device_id = ? ORDER BY seq DESC LIMIT 1 OFFSET ?)`,
        device, device, LIMITS.maxEventsPerDevice,
      );
      await this.scheduleExpiry(earliestExpiry);
    }
    // Live viewers get only the newest point of a batch (clients send batches oldest-first);
    // the rest is available through history.
    if (latest) for (const viewer of this.viewersOf(device)) this.sendTo(viewer, { type: "event", event: latest });
    return res;
  }

  private async scheduleExpiry(at: number): Promise<void> {
    const current = await this.ctx.storage.getAlarm();
    if (current === null || at < current) await this.ctx.storage.setAlarm(at);
  }

  /** Retention enforcement: delete everything past its expiry, then wake up at the next one. */
  override async alarm(): Promise<void> {
    if (!this.initialized()) return;
    const now = Date.now();
    this.sql.exec("DELETE FROM events WHERE expires_at <= ?", now);
    this.sql.exec("DELETE FROM nonces WHERE expires_at < ?", now);
    this.sql.exec("DELETE FROM invitations WHERE expires_at < ?", now - 86_400_000);
    const next = this.sql.exec("SELECT MIN(expires_at) AS t FROM events").one().t as number | null;
    if (next !== null) await this.ctx.storage.setAlarm(next);
  }

  // ---------------------------------------------------------------- WebSocket

  private openSocket(me: Member): Response {
    const wasOnline = this.online().has(me.device_id);
    const { 0: client, 1: server } = new WebSocketPair();
    this.ctx.acceptWebSocket(server, [me.device_id]);
    server.send(JSON.stringify({ type: "hello", device_id: me.device_id, online: [...this.online()] } satisfies ServerMessage));
    if (!wasOnline) this.broadcast({ type: "presence", device_id: me.device_id, online: true }, me.device_id);
    return new Response(null, { status: 101, webSocket: client });
  }

  override async webSocketMessage(ws: WebSocket, message: string | ArrayBuffer): Promise<void> {
    const device = this.ctx.getTags(ws)[0]!;
    const send = (m: ServerMessage) => ws.send(JSON.stringify(m));
    if (!this.member(device)) return ws.close(4001, "not_a_member");
    const now = Date.now();
    if (!this.allow(device, now)) return send({ type: "error", error: "rate_limited" });
    if (typeof message !== "string" || message.length > LIMITS.maxBodyBytes) return send({ type: "error", error: "invalid_message" });

    let msg: Record<string, unknown>;
    try {
      msg = JSON.parse(message) as Record<string, unknown>;
    } catch {
      return send({ type: "error", error: "invalid_message" });
    }
    switch (msg.type) {
      case "publish": {
        const r = await this.publish(device, msg.events, now);
        return send(typeof r === "string" ? { type: "error", error: r } : { type: "published", ...r });
      }
      case "signal": {
        // WebRTC signaling: forwarded verbatim (SDP/ICE), only between members.
        const size = JSON.stringify(msg.data ?? null).length;
        if (!isId(msg.to) || msg.to === device || !this.member(msg.to) || size > LIMITS.maxSignalChars) {
          return send({ type: "error", error: "invalid_signal" });
        }
        return this.sendTo(msg.to, { type: "signal", from: device, data: msg.data });
      }
      case "ping":
        return send({ type: "pong" });
      default:
        return send({ type: "error", error: "unknown_type" });
    }
  }

  override async webSocketClose(ws: WebSocket, code: number): Promise<void> {
    const device = this.ctx.getTags(ws)[0];
    try {
      ws.close(code === 1005 ? 1000 : code);
    } catch {
      // Already closed.
    }
    if (device && this.initialized() && this.member(device) && !this.online().has(device)) {
      this.broadcast({ type: "presence", device_id: device, online: false }, device);
    }
  }

  override async webSocketError(ws: WebSocket): Promise<void> {
    await this.webSocketClose(ws, 1011);
  }

  private online(): Set<string> {
    const s = new Set<string>();
    for (const ws of this.ctx.getWebSockets()) {
      if (ws.readyState === WebSocket.OPEN) s.add(this.ctx.getTags(ws)[0]!);
    }
    return s;
  }

  private sendTo(device: string, m: ServerMessage): void {
    const data = JSON.stringify(m);
    for (const ws of this.ctx.getWebSockets(device)) {
      try {
        ws.send(data);
      } catch {
        // Socket is closing; it will be cleaned up by webSocketClose.
      }
    }
  }

  private broadcast(m: ServerMessage, except?: string): void {
    const data = JSON.stringify(m);
    for (const ws of this.ctx.getWebSockets()) {
      if (except && this.ctx.getTags(ws)[0] === except) continue;
      try {
        ws.send(data);
      } catch {
        // Ignore closing sockets.
      }
    }
  }

  // ---------------------------------------------------------------- helpers

  private initialized(): boolean {
    const hasMeta = this.sql.exec("SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'meta'").toArray().length > 0;
    return hasMeta && this.sql.exec("SELECT 1 FROM meta WHERE key = 'group_id'").toArray().length > 0;
  }

  private meta(key: string): string {
    return this.sql.exec("SELECT value FROM meta WHERE key = ?", key).one().value as string;
  }

  private member(deviceId: string): Member | null {
    const r = this.sql.exec("SELECT * FROM members WHERE device_id = ?", deviceId).toArray()[0];
    return r ? toMember(r) : null;
  }

  private memberCount(): number {
    return this.sql.exec("SELECT COUNT(*) AS n FROM members").one().n as number;
  }

  /** Devices `device` currently shares its location with. */
  private viewersOf(device: string): string[] {
    return this.sql.exec("SELECT to_id FROM cards WHERE from_id = ? AND shares = 1", device).toArray().map((r) => r.to_id as string);
  }

  /** Devices currently sharing their location with `device`. */
  private sharersTo(device: string): string[] {
    return this.sql.exec("SELECT from_id FROM cards WHERE to_id = ? AND shares = 1", device).toArray().map((r) => r.from_id as string);
  }

  private state(): GroupState {
    return {
      protocol_version: PROTOCOL_VERSION,
      group_id: this.meta("group_id"),
      created_at: Number(this.meta("created_at")),
      members: this.sql.exec("SELECT * FROM members ORDER BY joined_at, device_id").toArray().map(toMember),
      shares: this.sql
        .exec("SELECT from_id, to_id FROM cards WHERE shares = 1")
        .toArray()
        .map((r) => ({ from: r.from_id as string, to: r.to_id as string })),
    };
  }

  /** Replay protection: each (device, nonce) is accepted once while its timestamp is still fresh. */
  private consumeNonce(a: Verified, now: number): boolean {
    this.sql.exec("DELETE FROM nonces WHERE expires_at < ?", now);
    const key = `${a.deviceId}:${a.nonce}`;
    if (this.sql.exec("SELECT 1 FROM nonces WHERE nonce = ?", key).toArray().length) return false;
    this.sql.exec("INSERT INTO nonces (nonce, expires_at) VALUES (?, ?)", key, a.timestamp + LIMITS.authMaxSkewMs + 1000);
    return true;
  }

  private allow(device: string, now: number): boolean {
    const b = this.buckets.get(device) ?? { tokens: RATE.capacity, at: now };
    b.tokens = Math.min(RATE.capacity, b.tokens + ((now - b.at) / 1000) * RATE.perSecond);
    b.at = now;
    this.buckets.set(device, b);
    if (b.tokens < 1) return false;
    b.tokens -= 1;
    return true;
  }
}

function toMember(r: Row): Member {
  return {
    device_id: r.device_id as string,
    sign_pk: r.sign_pk as string,
    box_pk: r.box_pk as string,
    box_sig: r.box_sig as string,
    role: r.role as Member["role"],
    invited_by: (r.invited_by as string | null) ?? null,
    binding: (r.binding as string | null) ?? null,
    joined_at: r.joined_at as number,
  };
}
