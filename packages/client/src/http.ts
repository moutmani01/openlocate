import { memberKeys, signRequest, signWebSocket, type DeviceIdentity } from "@openlocate/crypto";
import {
  utf8,
  type CardRecord,
  type CreateInvitationRequest,
  type GroupState,
  type HistoryResponse,
  type JoinRequest,
  type LocationEvent,
  type PublishResponse,
  type PutCardRequest,
  type ServerInfo,
  type ServerMessage,
} from "@openlocate/protocol";
import type { BackendProvider, HistoryQuery, Subscription } from "./provider";

export class BackendError extends Error {
  constructor(
    readonly status: number,
    readonly code: string,
  ) {
    super(`${status} ${code}`);
  }
}

/**
 * Speaks the OpenLocate v1 HTTP + WebSocket protocol (docs/PROTOCOL.md). Works against the
 * Cloudflare backend in this repo or any other server implementing the same protocol.
 */
export class HttpProvider implements BackendProvider {
  private readonly base: string;

  constructor(
    baseUrl: string,
    private readonly identity: DeviceIdentity,
  ) {
    this.base = baseUrl.replace(/\/+$/, "");
  }

  private async call<T>(method: string, target: string, body?: unknown): Promise<T> {
    const bytes = body === undefined ? new Uint8Array(0) : utf8(JSON.stringify(body));
    const headers: Record<string, string> = signRequest(this.identity, method, target, bytes);
    if (body !== undefined) headers["content-type"] = "application/json";
    const res = await fetch(this.base + target, {
      method,
      headers,
      body: body === undefined ? undefined : (bytes as Uint8Array<ArrayBuffer>),
    });
    if (!res.ok) {
      const err = (await res.json().catch(() => ({}))) as { error?: string };
      throw new BackendError(res.status, err.error ?? "unknown");
    }
    return (res.status === 204 ? undefined : await res.json()) as T;
  }

  private g(groupId: string, rest = ""): string {
    return `/v1/groups/${groupId}${rest}`;
  }

  async info(): Promise<ServerInfo> {
    const res = await fetch(this.base + "/v1/info");
    return (await res.json()) as ServerInfo;
  }

  createGroup(groupId: string) {
    return this.call<GroupState>("PUT", this.g(groupId), { member: memberKeys(this.identity) });
  }

  getGroup(groupId: string) {
    return this.call<GroupState>("GET", this.g(groupId));
  }

  createInvitation(groupId: string, req: CreateInvitationRequest) {
    return this.call<void>("POST", this.g(groupId, "/invitations"), req);
  }

  revokeInvitation(groupId: string, inviteId: string) {
    return this.call<void>("DELETE", this.g(groupId, `/invitations/${inviteId}`));
  }

  joinGroup(groupId: string, req: JoinRequest) {
    return this.call<GroupState>("POST", this.g(groupId, "/join"), req);
  }

  removeMember(groupId: string, deviceId: string) {
    return this.call<void>("DELETE", this.g(groupId, `/members/${deviceId}`));
  }

  putCard(groupId: string, to: string, req: PutCardRequest) {
    return this.call<void>("PUT", this.g(groupId, `/cards/${to}`), req);
  }

  async getCards(groupId: string) {
    return (await this.call<{ cards: CardRecord[] }>("GET", this.g(groupId, "/cards"))).cards;
  }

  publishLocation(groupId: string, events: LocationEvent[]) {
    return this.call<PublishResponse>("POST", this.g(groupId, "/events"), { events });
  }

  getHistory(groupId: string, q: HistoryQuery = {}) {
    const params = new URLSearchParams();
    if (q.after != null) params.set("after", String(q.after));
    if (q.from) params.set("from", q.from);
    if (q.limit != null) params.set("limit", String(q.limit));
    const qs = params.toString();
    return this.call<HistoryResponse>("GET", this.g(groupId, "/events" + (qs ? `?${qs}` : "")));
  }

  deleteHistory(groupId: string, expiresBefore?: number) {
    return this.call<void>("DELETE", this.g(groupId, "/events" + (expiresBefore != null ? `?expires_before=${expiresBefore}` : "")));
  }

  subscribe(groupId: string, onMessage: (msg: ServerMessage) => void): Promise<Subscription> {
    const path = this.g(groupId, "/ws");
    const url = this.base.replace(/^http/, "ws") + path + "?" + signWebSocket(this.identity, path);
    const ws = new WebSocket(url);
    const closed = new Promise<void>((resolve) => ws.addEventListener("close", () => resolve()));
    ws.addEventListener("message", (e) => {
      try {
        onMessage(JSON.parse(String(e.data)) as ServerMessage);
      } catch {
        // Ignore malformed frames; the server is not trusted to send well-formed data.
      }
    });
    return new Promise((resolve, reject) => {
      ws.addEventListener("open", () =>
        resolve({ send: (m) => ws.send(JSON.stringify(m)), close: () => ws.close(1000), closed }),
      );
      ws.addEventListener("error", () => reject(new Error("websocket failed")));
    });
  }
}
