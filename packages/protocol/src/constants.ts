/** Wire protocol version. Bumped only for incompatible changes; see docs/PROTOCOL.md. */
export const PROTOCOL_VERSION = 1;

/** Domain-separation prefixes. Every signed or authenticated byte string starts with one. */
export const DOMAIN = {
  request: "OL1-REQ",
  boxKey: "OL1-BOXKEY",
  card: "OL1-CARD",
  join: "OL1-JOIN",
  location: "OL1-LOC",
} as const;

/** Hard limits enforced by every conforming server. Clients should stay well below them. */
export const LIMITS = {
  maxBodyBytes: 256 * 1024,
  maxMembers: 50,
  maxActiveInvitations: 20,
  maxInviteTtlMs: 24 * 60 * 60 * 1000,
  maxBatch: 200,
  maxPayloadChars: 2048,
  maxEnvelopeChars: 4096,
  maxSignalChars: 16 * 1024,
  maxEventsPerDevice: 50_000,
  historyPageSize: 500,
  authMaxSkewMs: 60_000,
} as const;
