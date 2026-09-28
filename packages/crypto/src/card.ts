import {
  DOMAIN,
  concatBytes,
  fromB64url,
  toB64url,
  utf8,
  type CardEnvelope,
  type MemberKeys,
} from "@openlocate/protocol";
import type { DeviceIdentity } from "./identity";
import { sodium } from "./sodium";

/**
 * What one member tells another, end-to-end encrypted. A card always carries the sender's
 * display name; it carries the sender's current location key only if the sender shares with
 * the recipient. Sharing is per-sender and per-recipient, so it is never implicitly reciprocal.
 */
export interface CardContent {
  v: 1;
  group_id: string;
  from: string;
  to: string;
  epoch: number;
  issued_at: number;
  display_name: string;
  /** base64url 32-byte XChaCha20-Poly1305 key; absent when not sharing with the recipient. */
  location_key?: string;
}

function signedBytes(groupId: string, to: string, sealed: Uint8Array): Uint8Array {
  return concatBytes(utf8([DOMAIN.card, groupId, to, ""].join("\n")), sealed);
}

export function sealCard(sender: DeviceIdentity, recipient: MemberKeys, content: CardContent): CardEnvelope {
  const s = sodium();
  if (content.from !== sender.deviceId || content.to !== recipient.device_id) throw new Error("card from/to mismatch");
  const sealed = s.crypto_box_seal(utf8(JSON.stringify(content)), fromB64url(recipient.box_pk));
  return {
    sealed: toB64url(sealed),
    sig: toB64url(s.crypto_sign_detached(signedBytes(content.group_id, content.to, sealed), sender.signSk)),
  };
}

/** Verifies the sender's signature, decrypts, and checks the inner header. Throws on any failure. */
export function openCard(
  recipient: DeviceIdentity,
  sender: MemberKeys,
  groupId: string,
  envelope: CardEnvelope,
): CardContent {
  const s = sodium();
  const sealed = fromB64url(envelope.sealed);
  const ok = s.crypto_sign_verify_detached(
    fromB64url(envelope.sig),
    signedBytes(groupId, recipient.deviceId, sealed),
    fromB64url(sender.sign_pk),
  );
  if (!ok) throw new Error("card signature invalid");
  const plain = s.crypto_box_seal_open(sealed, recipient.boxPk, recipient.boxSk);
  const c = JSON.parse(new TextDecoder().decode(plain)) as CardContent;
  if (c.v !== 1 || c.group_id !== groupId || c.from !== sender.device_id || c.to !== recipient.deviceId) {
    throw new Error("card header mismatch");
  }
  return c;
}
