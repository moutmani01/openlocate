import 'dart:typed_data';

import '../backend/backend_provider.dart';
import '../crypto/ol_crypto.dart';

/// The OS may deliver fixes more often than asked; send at most once per desired interval
/// (with 10% tolerance so a fix arriving slightly early is not skipped).
bool shouldSend(DateTime? lastSent, DateTime now, int intervalSeconds) =>
    lastSent == null || now.difference(lastSent).inMilliseconds >= intervalSeconds * 900;

/// When the server should delete an event, in Unix milliseconds. Live-only events (no retention)
/// are kept for one minute so they can still be relayed; stored ones are rounded up to the minute.
int expiryFor({required int fixSeconds, required int retentionHours, required int nowMs}) {
  final retentionMs = retentionHours * 3600 * 1000;
  return retentionMs == 0 ? nowMs + 60000 : ((fixSeconds * 1000 + retentionMs) / 60000).ceil() * 60000;
}

/// Encrypts one fix into the event the server stores and relays.
WireEvent buildLocationEvent(
  OlCrypto crypto, {
  required String groupId,
  required String deviceId,
  required int epoch,
  required Uint8List locationKey,
  required LocationPoint point,
  required int retentionHours,
  required DateTime now,
}) {
  final eventId = crypto.newEventId(deviceId);
  final ctx = EventContext(groupId: groupId, deviceId: deviceId, eventId: eventId, epoch: epoch);
  return WireEvent(
    deviceId: deviceId,
    eventId: eventId,
    epoch: epoch,
    payload: crypto.encryptLocation(locationKey, ctx, point),
    expiresAt: expiryFor(fixSeconds: point.ts, retentionHours: retentionHours, nowMs: now.millisecondsSinceEpoch),
    store: retentionHours > 0,
  );
}
