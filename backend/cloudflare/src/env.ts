export interface Env {
  GROUP: DurableObjectNamespace;
  /** Upper bound on history retention, in days. Clients cannot store events longer than this. */
  MAX_RETENTION_DAYS?: string;
  /** CORS origin for the web client. Auth is by signature, not cookies, so "*" is safe. */
  ALLOWED_ORIGIN?: string;
}

/** Headers the Worker sets after verifying a request; the Durable Object trusts only these. */
export const INTERNAL = {
  device: "x-ol-verified-device",
  signPk: "x-ol-verified-signpk",
  nonce: "x-ol-verified-nonce",
  timestamp: "x-ol-verified-ts",
  group: "x-ol-group",
} as const;

export function maxRetentionMs(env: Env): number {
  const days = Number(env.MAX_RETENTION_DAYS ?? "90");
  return (Number.isFinite(days) && days > 0 ? days : 90) * 24 * 60 * 60 * 1000;
}
