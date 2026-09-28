import { DOMAIN, fromB64url, toB64url, utf8, type MemberKeys } from "@openlocate/protocol";
import { sodium } from "./sodium";

const KDF_CONTEXT = "OLinvite"; // exactly 8 bytes, as libsodium requires

/**
 * Everything derived from one invitation secret. Only `inviteId` and `authHash` go to the
 * server when the invitation is created; the joiner later reveals `authKey`. `macKey` never
 * leaves the two phones, so the server cannot forge a join binding.
 */
export interface Invite {
  secret: Uint8Array;
  inviteId: string;
  authKey: Uint8Array;
  authHash: string;
  macKey: Uint8Array;
}

export function newInvite(): Invite {
  return deriveInvite(sodium().randombytes_buf(32));
}

export function deriveInvite(secret: Uint8Array): Invite {
  const s = sodium();
  if (secret.length !== 32) throw new Error("invite secret must be 32 bytes");
  const authKey = s.crypto_kdf_derive_from_key(32, 1, KDF_CONTEXT, secret);
  return {
    secret,
    inviteId: toB64url(s.crypto_kdf_derive_from_key(16, 3, KDF_CONTEXT, secret)),
    authKey,
    authHash: toB64url(s.crypto_hash_sha256(authKey)),
    macKey: s.crypto_kdf_derive_from_key(32, 2, KDF_CONTEXT, secret),
  };
}

function bindingMessage(groupId: string, m: MemberKeys): Uint8Array {
  return utf8([DOMAIN.join, groupId, m.sign_pk, m.box_pk].join("\n"));
}

/** Proves to the inviter that these keys belong to whoever scanned the QR code. */
export function joinBinding(invite: Invite, groupId: string, m: MemberKeys): string {
  return toB64url(sodium().crypto_auth_hmacsha256(bindingMessage(groupId, m), invite.macKey));
}

export function verifyJoinBinding(invite: Invite, groupId: string, m: MemberKeys, binding: string): boolean {
  try {
    return sodium().crypto_auth_hmacsha256_verify(fromB64url(binding), bindingMessage(groupId, m), invite.macKey);
  } catch {
    return false;
  }
}

/** Contents of the QR code / invite link. Short-lived and single-use; no permanent credentials. */
export interface InviteLink {
  backend: string;
  groupId: string;
  secret: Uint8Array;
  /** Device id of the inviter, so the joiner can check the server didn't substitute someone else. */
  inviter: string;
  expiresAt: number;
  /** Optional group label chosen by the inviter. */
  name?: string;
}

export function encodeInviteLink(l: InviteLink): string {
  const q = new URLSearchParams({
    b: l.backend,
    g: l.groupId,
    s: toB64url(l.secret),
    i: l.inviter,
    e: String(l.expiresAt),
  });
  if (l.name) q.set("n", l.name);
  return `openlocate://invite?${q}`;
}

export function decodeInviteLink(link: string): InviteLink {
  const u = new URL(link);
  if (u.protocol !== "openlocate:" || u.host !== "invite") throw new Error("not an OpenLocate invite");
  const get = (k: string) => {
    const v = u.searchParams.get(k);
    if (!v) throw new Error(`invite is missing '${k}'`);
    return v;
  };
  const backend = new URL(get("b"));
  if (backend.protocol !== "https:" && backend.hostname !== "localhost" && backend.hostname !== "127.0.0.1") {
    throw new Error("invite backend must use https");
  }
  return {
    backend: backend.origin,
    groupId: get("g"),
    secret: fromB64url(get("s")),
    inviter: get("i"),
    expiresAt: Number(get("e")),
    name: u.searchParams.get("n") ?? undefined,
  };
}
