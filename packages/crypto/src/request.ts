import { AUTH_HEADERS, WS_AUTH_PARAMS, requestSigningPayload, toB64url } from "@openlocate/protocol";
import type { DeviceIdentity } from "./identity";
import { sodium } from "./sodium";

function sign(id: DeviceIdentity, method: string, target: string, body: Uint8Array, now: number, fixedNonce?: string) {
  const s = sodium();
  const nonce = fixedNonce ?? toB64url(s.randombytes_buf(16));
  const payload = requestSigningPayload(method, target, now, nonce, toB64url(s.crypto_hash_sha256(body)));
  return { nonce, signature: toB64url(s.crypto_sign_detached(payload, id.signSk)) };
}

/** Headers authenticating one HTTP request. `target` is the path plus query string. */
export function signRequest(
  id: DeviceIdentity,
  method: string,
  target: string,
  body: Uint8Array = new Uint8Array(0),
  now = Date.now(),
  /** Test vectors only. Real requests must use a fresh random nonce. */
  fixedNonce?: string,
): Record<string, string> {
  const { nonce, signature } = sign(id, method, target, body, now, fixedNonce);
  return {
    [AUTH_HEADERS.signPk]: toB64url(id.signPk),
    [AUTH_HEADERS.timestamp]: String(now),
    [AUTH_HEADERS.nonce]: nonce,
    [AUTH_HEADERS.signature]: signature,
  };
}

/** Query string authenticating a WebSocket upgrade to `path`. */
export function signWebSocket(id: DeviceIdentity, path: string, now = Date.now()): string {
  const { nonce, signature } = sign(id, "GET", path, new Uint8Array(0), now);
  return new URLSearchParams({
    [WS_AUTH_PARAMS.signPk]: toB64url(id.signPk),
    [WS_AUTH_PARAMS.timestamp]: String(now),
    [WS_AUTH_PARAMS.nonce]: nonce,
    [WS_AUTH_PARAMS.signature]: signature,
  }).toString();
}
