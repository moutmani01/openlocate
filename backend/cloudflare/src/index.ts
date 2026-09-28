import { LIMITS, PROTOCOL_VERSION, type ServerInfo } from "@openlocate/protocol";
import { verifyRequest, verifyWebSocket } from "./auth";
import { INTERNAL, maxRetentionMs, type Env } from "./env";
import { error, json } from "./http";

export { GroupDurableObject } from "./group";

const GROUP_PATH = /^\/v1\/groups\/([A-Za-z0-9_-]{22})(\/[A-Za-z0-9_:/-]*)?$/;

function cors(env: Env, res: Response): Response {
  const r = new Response(res.body, res);
  r.headers.set("access-control-allow-origin", env.ALLOWED_ORIGIN ?? "*");
  r.headers.set("access-control-allow-methods", "GET, POST, PUT, DELETE, OPTIONS");
  r.headers.set("access-control-allow-headers", "content-type, x-ol-device, x-ol-timestamp, x-ol-nonce, x-ol-signature");
  r.headers.set("access-control-max-age", "86400");
  return r;
}

async function handle(req: Request, env: Env): Promise<Response> {
  const url = new URL(req.url);
  if (req.method === "OPTIONS") return new Response(null, { status: 204 });

  if (url.pathname === "/v1/info" && req.method === "GET") {
    const info: ServerInfo = { protocol_version: PROTOCOL_VERSION, max_retention_ms: maxRetentionMs(env), limits: { ...LIMITS } };
    return json(info);
  }

  const m = GROUP_PATH.exec(url.pathname);
  if (!m) return error(404, "not_found");
  const groupId = m[1]!;
  const sub = m[2] ?? "";
  const isWs = sub === "/ws";

  let body = new Uint8Array(0);
  if (isWs) {
    if (req.headers.get("upgrade")?.toLowerCase() !== "websocket") return error(426, "upgrade_required");
  } else {
    if (Number(req.headers.get("content-length") ?? 0) > LIMITS.maxBodyBytes) return error(413, "too_large");
    body = new Uint8Array(await req.arrayBuffer());
    if (body.length > LIMITS.maxBodyBytes) return error(413, "too_large");
  }

  const auth = isWs ? await verifyWebSocket(url) : await verifyRequest(req, url, body);
  if (!auth.ok) return error(401, auth.reason);

  const headers = new Headers({
    [INTERNAL.device]: auth.v.deviceId,
    [INTERNAL.signPk]: auth.v.signPk,
    [INTERNAL.nonce]: auth.v.nonce,
    [INTERNAL.timestamp]: String(auth.v.timestamp),
    [INTERNAL.group]: groupId,
  });
  if (isWs) headers.set("upgrade", "websocket");
  if (body.length) headers.set("content-type", "application/json");

  const stub = env.GROUP.get(env.GROUP.idFromName(groupId));
  // Only the path below the group and the non-auth query reach the Durable Object.
  const inner = new URL(`https://group${sub}`);
  if (!isWs) inner.search = url.search;
  return stub.fetch(inner.toString(), {
    method: req.method,
    headers,
    body: body.length ? body : undefined,
  });
}

export default {
  async fetch(req: Request, env: Env): Promise<Response> {
    let res: Response;
    try {
      res = await handle(req, env);
    } catch {
      // Never log request contents: they may contain (encrypted) locations or keys.
      res = error(500, "internal");
    }
    return res.status === 101 ? res : cors(env, res);
  },
} satisfies ExportedHandler<Env>;
