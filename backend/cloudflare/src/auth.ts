import {
  AUTH_HEADERS,
  DOMAIN,
  LIMITS,
  WS_AUTH_PARAMS,
  concatBytes,
  deviceIdFromSignPk,
  fromB64url,
  isB64urlBytes,
  isId,
  requestSigningPayload,
  sha256,
  toB64url,
  utf8,
} from "@openlocate/protocol";

export interface Verified {
  deviceId: string;
  signPk: string;
  nonce: string;
  timestamp: number;
}

type Result = { ok: true; v: Verified } | { ok: false; reason: string };

async function ed25519Verify(pk: Uint8Array, sig: Uint8Array, msg: Uint8Array): Promise<boolean> {
  try {
    const key = await crypto.subtle.importKey("raw", pk, { name: "Ed25519" }, false, ["verify"]);
    return await crypto.subtle.verify({ name: "Ed25519" }, key, sig, msg);
  } catch {
    return false;
  }
}

async function verify(
  method: string,
  target: string,
  body: Uint8Array,
  signPk: string | null,
  ts: string | null,
  nonce: string | null,
  sig: string | null,
  now: number,
): Promise<Result> {
  if (!isB64urlBytes(signPk, 32) || !ts || !isB64urlBytes(nonce, 16) || !isB64urlBytes(sig, 64)) {
    return { ok: false, reason: "missing_or_malformed_auth" };
  }
  const timestamp = Number(ts);
  if (!Number.isSafeInteger(timestamp) || Math.abs(now - timestamp) > LIMITS.authMaxSkewMs) {
    return { ok: false, reason: "stale_request" };
  }
  const pk = fromB64url(signPk);
  const payload = requestSigningPayload(method, target, timestamp, nonce, toB64url(await sha256(body)));
  if (!(await ed25519Verify(pk, fromB64url(sig), payload))) return { ok: false, reason: "bad_signature" };
  return { ok: true, v: { deviceId: await deviceIdFromSignPk(pk), signPk, nonce, timestamp } };
}

export function verifyRequest(req: Request, url: URL, body: Uint8Array, now = Date.now()): Promise<Result> {
  const h = (k: string) => req.headers.get(k);
  return verify(
    req.method,
    url.pathname + url.search,
    body,
    h(AUTH_HEADERS.signPk),
    h(AUTH_HEADERS.timestamp),
    h(AUTH_HEADERS.nonce),
    h(AUTH_HEADERS.signature),
    now,
  );
}

export function verifyWebSocket(url: URL, now = Date.now()): Promise<Result> {
  const q = (k: string) => url.searchParams.get(k);
  return verify(
    "GET",
    url.pathname,
    new Uint8Array(0),
    q(WS_AUTH_PARAMS.signPk),
    q(WS_AUTH_PARAMS.timestamp),
    q(WS_AUTH_PARAMS.nonce),
    q(WS_AUTH_PARAMS.signature),
    now,
  );
}

/** A member record is valid if its id derives from its key and its box key is signed by it. */
export async function validMemberKeys(m: unknown, signedBy: Verified): Promise<boolean> {
  if (typeof m !== "object" || m === null) return false;
  const k = m as Record<string, unknown>;
  if (!isId(k.device_id) || !isB64urlBytes(k.sign_pk, 32) || !isB64urlBytes(k.box_pk, 32) || !isB64urlBytes(k.box_sig, 64)) {
    return false;
  }
  if (k.sign_pk !== signedBy.signPk || k.device_id !== signedBy.deviceId) return false;
  const msg = concatBytes(utf8(DOMAIN.boxKey + "\n"), fromB64url(k.box_pk));
  return ed25519Verify(fromB64url(k.sign_pk), fromB64url(k.box_sig), msg);
}
