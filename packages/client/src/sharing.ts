import { fromB64url, toB64url, type GroupState, type RelayedEvent } from "@openlocate/protocol";
import {
  decryptLocation,
  encryptLocation,
  newEventId,
  newLocationKey,
  openCard,
  sealCard,
  verifyMemberKeys,
  type DeviceIdentity,
  type LocationPoint,
} from "@openlocate/crypto";
import type { BackendProvider } from "./provider";

/** This device's outgoing sharing state for one group. Persisted locally (encrypted). */
export interface SharingState {
  displayName: string;
  epoch: number;
  locationKey: Uint8Array;
  /** Device ids allowed to see this device's location. Empty = sharing off. */
  shareWith: Set<string>;
}

export function newSharingState(displayName: string): SharingState {
  return { displayName, epoch: 1, locationKey: newLocationKey(), shareWith: new Set() };
}

/**
 * New key, next epoch. Call whenever someone loses access (removed from shareWith, left or was
 * removed from the group), then publishCards: people who lost access never receive the new key.
 */
export function rotateKey(s: SharingState): SharingState {
  return { ...s, epoch: s.epoch + 1, locationKey: newLocationKey() };
}

/** Send every other member a card: name for all, location key only for those in shareWith. */
export async function publishCards(
  backend: BackendProvider,
  me: DeviceIdentity,
  group: GroupState,
  s: SharingState,
  now = Date.now(),
): Promise<void> {
  for (const m of group.members) {
    if (m.device_id === me.deviceId || !verifyMemberKeys(m)) continue;
    const shares = s.shareWith.has(m.device_id);
    const envelope = sealCard(me, m, {
      v: 1,
      group_id: group.group_id,
      from: me.deviceId,
      to: m.device_id,
      epoch: s.epoch,
      issued_at: now,
      display_name: s.displayName,
      ...(shares ? { location_key: toB64url(s.locationKey) } : {}),
    });
    await backend.putCard(group.group_id, m.device_id, { envelope, epoch: s.epoch, shares_location: shares });
  }
}

export interface Peer {
  deviceId: string;
  displayName: string;
  /** True if this peer currently shares their location with us. */
  sharing: boolean;
}

/**
 * Location keys received from peers, by device and epoch. Old epochs are kept so history
 * encrypted before a rotation stays readable for people who were allowed to see it.
 */
export class Keyring {
  private keys = new Map<string, Map<number, Uint8Array>>();
  readonly peers = new Map<string, Peer>();

  /** Fetch, verify and open every card addressed to this device. Invalid cards are skipped. */
  async refresh(backend: BackendProvider, me: DeviceIdentity, group: GroupState): Promise<void> {
    const members = new Map(group.members.map((m) => [m.device_id, m]));
    for (const rec of await backend.getCards(group.group_id)) {
      const sender = members.get(rec.from);
      if (!sender || !verifyMemberKeys(sender)) continue;
      try {
        const card = openCard(me, sender, group.group_id, rec.envelope);
        if (card.location_key) {
          const byEpoch = this.keys.get(card.from) ?? new Map<number, Uint8Array>();
          byEpoch.set(card.epoch, fromB64url(card.location_key));
          this.keys.set(card.from, byEpoch);
        }
        this.peers.set(card.from, { deviceId: card.from, displayName: card.display_name, sharing: !!card.location_key });
      } catch {
        // Forged or corrupted card: ignore it rather than trusting the server.
      }
    }
    for (const id of this.peers.keys()) if (!members.has(id)) this.peers.delete(id);
  }

  /** Decrypt an event, or return null if we hold no key for its sender/epoch or it fails authentication. */
  decrypt(groupId: string, e: Pick<RelayedEvent, "device_id" | "event_id" | "epoch" | "payload">): LocationPoint | null {
    const key = this.keys.get(e.device_id)?.get(e.epoch);
    if (!key) return null;
    try {
      return decryptLocation(key, { groupId, deviceId: e.device_id, eventId: e.event_id, epoch: e.epoch }, e.payload);
    } catch {
      return null;
    }
  }
}

/** Default: round expiry up to the next minute so the server learns fix times only to the minute. */
export const EXPIRY_ROUNDING_MS = 60_000;

/** Build an encrypted, ready-to-publish event for one location fix. */
export function sealLocation(
  me: DeviceIdentity,
  groupId: string,
  s: SharingState,
  point: LocationPoint,
  retentionMs: number,
  roundingMs = EXPIRY_ROUNDING_MS,
) {
  const eventId = newEventId(me.deviceId);
  const expires = point.ts * 1000 + retentionMs;
  return {
    event_id: eventId,
    epoch: s.epoch,
    payload: encryptLocation(s.locationKey, { groupId, deviceId: me.deviceId, eventId, epoch: s.epoch }, point),
    expires_at: Math.ceil(expires / roundingMs) * roundingMs,
    store: retentionMs > 0,
  };
}
