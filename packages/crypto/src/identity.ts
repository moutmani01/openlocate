import { DOMAIN, concatBytes, fromB64url, toB64url, utf8, type MemberKeys } from "@openlocate/protocol";
import { sodium } from "./sodium";

/**
 * A device's long-term identity. Generated on the device; the secret keys never leave it
 * (on mobile they live in the Android Keystore / iOS Keychain via secure storage).
 */
export interface DeviceIdentity {
  deviceId: string;
  signPk: Uint8Array;
  signSk: Uint8Array;
  boxPk: Uint8Array;
  boxSk: Uint8Array;
}

export function deviceIdOf(signPk: Uint8Array): string {
  return toB64url(sodium().crypto_hash_sha256(signPk).subarray(0, 16));
}

export function createIdentity(): DeviceIdentity {
  const s = sodium();
  const sign = s.crypto_sign_keypair();
  const box = s.crypto_box_keypair();
  return fromKeypairs(sign.publicKey, sign.privateKey, box.publicKey, box.privateKey);
}

/** Deterministic identity from two 32-byte seeds. For test vectors only. */
export function identityFromSeeds(signSeed: Uint8Array, boxSeed: Uint8Array): DeviceIdentity {
  const s = sodium();
  const sign = s.crypto_sign_seed_keypair(signSeed);
  const box = s.crypto_box_seed_keypair(boxSeed);
  return fromKeypairs(sign.publicKey, sign.privateKey, box.publicKey, box.privateKey);
}

function fromKeypairs(signPk: Uint8Array, signSk: Uint8Array, boxPk: Uint8Array, boxSk: Uint8Array): DeviceIdentity {
  return { deviceId: deviceIdOf(signPk), signPk, signSk, boxPk, boxSk };
}

/** Serialize for OS secure storage. Never send this anywhere. */
export function exportIdentity(id: DeviceIdentity): string {
  return JSON.stringify({ v: 1, sign_sk: toB64url(id.signSk), box_sk: toB64url(id.boxSk) });
}

export function importIdentity(json: string): DeviceIdentity {
  const s = sodium();
  const o = JSON.parse(json) as { v: number; sign_sk: string; box_sk: string };
  if (o.v !== 1) throw new Error("unsupported identity version");
  const signSk = fromB64url(o.sign_sk);
  const boxSk = fromB64url(o.box_sk);
  return fromKeypairs(s.crypto_sign_ed25519_sk_to_pk(signSk), signSk, s.crypto_scalarmult_base(boxSk), boxSk);
}

function boxKeyMessage(boxPk: Uint8Array): Uint8Array {
  return concatBytes(utf8(DOMAIN.boxKey + "\n"), boxPk);
}

/** The public record a device publishes to a group. */
export function memberKeys(id: DeviceIdentity): MemberKeys {
  return {
    device_id: id.deviceId,
    sign_pk: toB64url(id.signPk),
    box_pk: toB64url(id.boxPk),
    box_sig: toB64url(sodium().crypto_sign_detached(boxKeyMessage(id.boxPk), id.signSk)),
  };
}

/** Checks the device id derivation and that the box key is signed by the identity key. */
export function verifyMemberKeys(m: MemberKeys): boolean {
  try {
    const signPk = fromB64url(m.sign_pk);
    const boxPk = fromB64url(m.box_pk);
    return (
      signPk.length === 32 &&
      boxPk.length === 32 &&
      deviceIdOf(signPk) === m.device_id &&
      sodium().crypto_sign_verify_detached(fromB64url(m.box_sig), boxKeyMessage(boxPk), signPk)
    );
  } catch {
    return false;
  }
}

/**
 * Human-comparable safety number for out-of-band verification ("compare these digits in person").
 * 12 groups of 5 digits derived from SHA-256 of the identity key.
 */
export function safetyNumber(signPk: Uint8Array): string {
  const h = sodium().crypto_hash_sha256(concatBytes(utf8("OL1-SAFETY\n"), signPk));
  const groups: string[] = [];
  for (let i = 0; i < 12; i++) {
    const n = ((h[i * 2]! << 16) | (h[i * 2 + 1]! << 8) | h[24 + (i % 8)]!) % 100000;
    groups.push(String(n).padStart(5, "0"));
  }
  return groups.join(" ");
}
