const ID = /^[A-Za-z0-9_-]{22}$/;
const B64URL = /^[A-Za-z0-9_-]+$/;

/** 16 bytes, base64url (22 chars). Used for device, group and invitation ids. */
export function isId(v: unknown): v is string {
  return typeof v === "string" && ID.test(v);
}

/** Canonical unpadded base64url decoding to exactly `bytes` bytes. */
export function isB64urlBytes(v: unknown, bytes: number): v is string {
  return typeof v === "string" && v.length === Math.ceil((bytes * 4) / 3) && B64URL.test(v);
}

export function isB64url(v: unknown, maxChars: number): v is string {
  return typeof v === "string" && v.length <= maxChars && B64URL.test(v);
}

/** Event ids are "<device_id>:<22-char id>", so a device can only publish under its own prefix. */
export function isEventIdFor(v: unknown, deviceId: string): v is string {
  return typeof v === "string" && v.length === 45 && v.startsWith(deviceId + ":") && ID.test(v.slice(23));
}

export function isInt(v: unknown, min = 0, max = Number.MAX_SAFE_INTEGER): v is number {
  return typeof v === "number" && Number.isInteger(v) && v >= min && v <= max;
}
