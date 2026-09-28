import { randomBytes } from "node:crypto";
import { mkdtempSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import { unstable_dev } from "wrangler";
import { HttpProvider, newSharingState, type SharingState } from "@openlocate/client";
import { createIdentity, initCrypto, joinBinding, memberKeys, newInvite, type DeviceIdentity } from "@openlocate/crypto";
import { toB64url, type GroupState, type ServerMessage } from "@openlocate/protocol";

/** Runs the real Worker (from wrangler.toml) in local workerd with SQLite Durable Objects. */
export async function startBackend(): Promise<{ url: string; dispose: () => Promise<void> }> {
  await initCrypto();
  const dir = fileURLToPath(new URL("..", import.meta.url));
  const worker = await unstable_dev(join(dir, "src/index.ts"), {
    config: join(dir, "wrangler.toml"),
    ip: "127.0.0.1",
    persistTo: mkdtempSync(join(tmpdir(), "openlocate-test-")),
    logLevel: "warn",
    experimental: { disableExperimentalWarning: true },
  });
  return { url: `http://${worker.address}:${worker.port}`, dispose: () => worker.stop() };
}

export interface Device {
  id: DeviceIdentity;
  api: HttpProvider;
  sharing: SharingState;
}

export function device(url: string, name: string): Device {
  const id = createIdentity();
  return { id, api: new HttpProvider(url, id), sharing: newSharingState(name) };
}

export function newGroupId(): string {
  return toB64url(randomBytes(16));
}

/** Full invite flow: `inviter` creates an invitation, `joiner` redeems it. */
export async function invite(inviter: Device, joiner: Device, groupId: string, ttlMs = 600_000): Promise<GroupState> {
  const inv = newInvite();
  await inviter.api.createInvitation(groupId, { invite_id: inv.inviteId, auth_hash: inv.authHash, expires_at: Date.now() + ttlMs });
  const keys = memberKeys(joiner.id);
  return joiner.api.joinGroup(groupId, {
    invite_id: inv.inviteId,
    auth_key: toB64url(inv.authKey),
    member: keys,
    binding: joinBinding(inv, groupId, keys),
  });
}

/** Collects WebSocket messages and lets a test wait for one matching a predicate. */
export class Inbox {
  readonly messages: ServerMessage[] = [];
  private waiters: { pred: (m: ServerMessage) => boolean; resolve: (m: ServerMessage) => void }[] = [];

  push = (m: ServerMessage) => {
    this.messages.push(m);
    this.waiters = this.waiters.filter((w) => (w.pred(m) ? (w.resolve(m), false) : true));
  };

  waitFor<T extends ServerMessage["type"]>(
    type: T,
    pred: (m: Extract<ServerMessage, { type: T }>) => boolean = () => true,
    timeoutMs = 5000,
  ): Promise<Extract<ServerMessage, { type: T }>> {
    const match = (m: ServerMessage) => m.type === type && pred(m as Extract<ServerMessage, { type: T }>);
    const found = this.messages.find(match);
    if (found) return Promise.resolve(found as Extract<ServerMessage, { type: T }>);
    return new Promise((resolve, reject) => {
      const t = setTimeout(() => reject(new Error(`timed out waiting for ${type}`)), timeoutMs);
      this.waiters.push({
        pred: match,
        resolve: (m) => {
          clearTimeout(t);
          resolve(m as Extract<ServerMessage, { type: T }>);
        },
      });
    });
  }
}

export const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));
