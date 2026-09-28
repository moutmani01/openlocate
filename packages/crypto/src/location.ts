import { DOMAIN, concatBytes, fromB64url, toB64url, utf8 } from "@openlocate/protocol";
import { sodium } from "./sodium";

/** Only the fields that are actually useful. Everything optional is omitted when unknown. */
export interface LocationPoint {
  /** Unix seconds of the fix. */
  ts: number;
  lat: number;
  lon: number;
  /** Horizontal accuracy, metres. */
  acc?: number;
  alt?: number;
  /** m/s */
  spd?: number;
  /** degrees */
  hdg?: number;
  /** Battery percent. Only included if the user opted in. */
  bat?: number;
}

export interface EventContext {
  groupId: string;
  deviceId: string;
  eventId: string;
  epoch: number;
}

const NONCE_BYTES = 24;
/** Plaintexts are padded to a multiple of this, so ciphertext length doesn't reveal which fields are present. */
const PAD_BLOCK = 64;

export function newLocationKey(): Uint8Array {
  return sodium().crypto_aead_xchacha20poly1305_ietf_keygen();
}

export function newEventId(deviceId: string): string {
  return `${deviceId}:${toB64url(sodium().randombytes_buf(16))}`;
}

function aad(ctx: EventContext): Uint8Array {
  return utf8([DOMAIN.location, ctx.groupId, ctx.deviceId, ctx.eventId, String(ctx.epoch)].join("\n"));
}

function canonical(p: LocationPoint): LocationPoint {
  const r = (n: number, d: number) => Math.round(n * 10 ** d) / 10 ** d;
  const out: LocationPoint = { ts: Math.round(p.ts), lat: r(p.lat, 6), lon: r(p.lon, 6) };
  if (p.acc != null) out.acc = r(p.acc, 1);
  if (p.alt != null) out.alt = r(p.alt, 1);
  if (p.spd != null) out.spd = r(p.spd, 1);
  if (p.hdg != null) out.hdg = Math.round(p.hdg);
  if (p.bat != null) out.bat = Math.round(p.bat);
  return out;
}

/**
 * XChaCha20-Poly1305 with the event's identity (group, sender, event id, key epoch) as associated
 * data, so the server cannot move a ciphertext to another sender, event or epoch undetected.
 */
export function encryptLocation(key: Uint8Array, ctx: EventContext, point: LocationPoint, nonce?: Uint8Array): string {
  const s = sodium();
  const n = nonce ?? s.randombytes_buf(NONCE_BYTES);
  const plain = s.pad(utf8(JSON.stringify(canonical(point))), PAD_BLOCK);
  const ct = s.crypto_aead_xchacha20poly1305_ietf_encrypt(plain, aad(ctx), null, n, key);
  return toB64url(concatBytes(n, ct));
}

export function decryptLocation(key: Uint8Array, ctx: EventContext, payload: string): LocationPoint {
  const s = sodium();
  const raw = fromB64url(payload);
  if (raw.length < NONCE_BYTES + 16) throw new Error("payload too short");
  const plain = s.crypto_aead_xchacha20poly1305_ietf_decrypt(
    null,
    raw.subarray(NONCE_BYTES),
    aad(ctx),
    raw.subarray(0, NONCE_BYTES),
    key,
  );
  const p = JSON.parse(new TextDecoder().decode(s.unpad(plain, PAD_BLOCK))) as LocationPoint;
  if (typeof p.ts !== "number" || typeof p.lat !== "number" || typeof p.lon !== "number") {
    throw new Error("malformed location");
  }
  return p;
}
