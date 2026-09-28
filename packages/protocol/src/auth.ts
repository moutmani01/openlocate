import { DOMAIN } from "./constants";
import { utf8 } from "./encoding";

/** HTTP headers carrying a signed request. See docs/PROTOCOL.md#request-authentication. */
export const AUTH_HEADERS = {
  signPk: "x-ol-device",
  timestamp: "x-ol-timestamp",
  nonce: "x-ol-nonce",
  signature: "x-ol-signature",
} as const;

/** Query parameters carrying the same fields for WebSocket upgrades (browsers cannot set headers). */
export const WS_AUTH_PARAMS = { signPk: "device", timestamp: "ts", nonce: "nonce", signature: "sig" } as const;

/**
 * The exact byte string a device signs with Ed25519 for each request.
 * `target` is path + query for HTTP, and the bare path for WebSocket upgrades.
 * `bodyHash` is base64url(SHA-256(body)); an empty body is hashed like any other.
 */
export function requestSigningPayload(
  method: string,
  target: string,
  timestampMs: number,
  nonce: string,
  bodyHash: string,
): Uint8Array {
  return utf8([DOMAIN.request, method.toUpperCase(), target, String(timestampMs), nonce, bodyHash].join("\n"));
}
