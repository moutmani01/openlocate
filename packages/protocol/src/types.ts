/** Public keys a device publishes. All binary fields are base64url. */
export interface MemberKeys {
  device_id: string;
  /** Ed25519 public key (identity). device_id = b64url(SHA-256(sign_pk)[0..16]). */
  sign_pk: string;
  /** X25519 public key, used to seal key cards to this device. */
  box_pk: string;
  /** Ed25519 signature by sign_pk over "OL1-BOXKEY\n" || box_pk. */
  box_sig: string;
}

export type Role = "admin" | "member";

export interface Member extends MemberKeys {
  role: Role;
  invited_by: string | null;
  /** HMAC proving the joiner held the invitation secret; only the inviter can verify it. */
  binding: string | null;
  joined_at: number;
}

export interface Share {
  from: string;
  to: string;
}

export interface GroupState {
  protocol_version: number;
  group_id: string;
  created_at: number;
  members: Member[];
  /** Who currently shares location with whom (derived from key cards). Never reciprocal by default. */
  shares: Share[];
}

export interface CreateGroupRequest {
  member: MemberKeys;
}

export interface CreateInvitationRequest {
  invite_id: string;
  /** b64url(SHA-256(auth_key)). The server never sees the invitation secret itself. */
  auth_hash: string;
  expires_at: number;
}

export interface JoinRequest {
  invite_id: string;
  auth_key: string;
  member: MemberKeys;
  binding: string;
}

/** A key card: a sealed box to the recipient, signed by the sender. Opaque to the server. */
export interface CardEnvelope {
  sealed: string;
  sig: string;
}

export interface PutCardRequest {
  envelope: CardEnvelope;
  epoch: number;
  /** Whether this card carries a location key. Drives server-side access control for history and relay. */
  shares_location: boolean;
}

export interface CardRecord {
  from: string;
  to: string;
  envelope: CardEnvelope;
  epoch: number;
  shares_location: boolean;
  updated_at: number;
}

/** An encrypted location event. The server sees only these fields. */
export interface LocationEvent {
  /** "<device_id>:<22-char random>" — globally unique, used for de-duplication. */
  event_id: string;
  /** Epoch of the sender's location key that encrypted `payload`. */
  epoch: number;
  /** b64url(nonce || XChaCha20-Poly1305 ciphertext). */
  payload: string;
  /** Unix ms after which the server must delete the event. Clients round it up to hide the exact fix time. */
  expires_at: number;
  /** false = relay to live viewers only, never persist. Defaults to true. */
  store?: boolean;
}

export interface RelayedEvent {
  device_id: string;
  event_id: string;
  epoch: number;
  payload: string;
  /** Server sequence number, or null for live-only events. */
  seq: number | null;
}

export interface StoredEvent extends RelayedEvent {
  seq: number;
  expires_at: number;
}

export interface PublishRequest {
  events: LocationEvent[];
}

export interface PublishResponse {
  accepted: number;
  duplicates: number;
  expired: number;
}

export interface HistoryResponse {
  events: StoredEvent[];
  /** Pass as `after` to fetch the next page. */
  next_after: number;
  more: boolean;
}

export interface ServerInfo {
  protocol_version: number;
  max_retention_ms: number;
  limits: Record<string, number>;
}

export type ClientMessage =
  | { type: "publish"; events: LocationEvent[] }
  | { type: "signal"; to: string; data: unknown }
  | { type: "ping" };

export type ServerMessage =
  | { type: "hello"; device_id: string; online: string[] }
  | { type: "event"; event: RelayedEvent }
  | { type: "published"; accepted: number; duplicates: number; expired: number }
  | { type: "signal"; from: string; data: unknown }
  | { type: "presence"; device_id: string; online: boolean }
  | { type: "member_joined"; device_id: string }
  | { type: "member_left"; device_id: string }
  | { type: "card_updated"; from: string }
  | { type: "pong" }
  | { type: "error"; error: string };
