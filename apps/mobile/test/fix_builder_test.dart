import 'package:flutter_test/flutter_test.dart';
import 'package:openlocate/backend/backend_provider.dart';
import 'package:openlocate/crypto/ol_crypto.dart';
import 'package:openlocate/format.dart';
import 'package:openlocate/location/fix_builder.dart';
import 'package:sodium/sodium_sumo.dart';

void main() {
  test('fixes are sent at most once per desired interval', () {
    final t0 = DateTime(2026, 1, 1, 12);
    expect(shouldSend(null, t0, 60), isTrue);
    expect(shouldSend(t0, t0.add(const Duration(seconds: 20)), 60), isFalse);
    expect(shouldSend(t0, t0.add(const Duration(seconds: 55)), 60), isTrue, reason: '10% early is accepted');
    expect(shouldSend(t0, t0.add(const Duration(seconds: 60)), 60), isTrue);
  });

  test('expiry follows the chosen retention', () {
    const fix = 1767268800; // seconds, on a whole minute
    final nowMs = fix * 1000 + 5000;
    expect(expiryFor(fixSeconds: fix, retentionHours: 0, nowMs: nowMs), nowMs + 60000, reason: 'live only: one minute to relay');
    expect(expiryFor(fixSeconds: fix, retentionHours: 24, nowMs: nowMs), (fix + 24 * 3600) * 1000);
    expect(expiryFor(fixSeconds: fix + 1, retentionHours: 1, nowMs: nowMs) % 60000, 0, reason: 'rounded up to the minute');
  });

  test('notification text', () {
    expect(sharingNotificationText(1, 60), 'Visible to 1 person · every 1 min');
    expect(sharingNotificationText(3, 15), 'Visible to 3 people · every 15 s');
  });

  test('a queued event decrypts back to the same fix after a round trip through the queue format', () async {
    final c = OlCrypto(await SodiumSumoInit.init());
    final me = c.createIdentity();
    final key = c.newLocationKey();
    final point = LocationPoint(ts: 1767268800, lat: 33.5731, lon: -7.5898, acc: 12, spd: 1.5, hdg: 90);

    final event = buildLocationEvent(
      c,
      groupId: 'group-1',
      deviceId: me.deviceId,
      epoch: 3,
      locationKey: key,
      point: point,
      retentionHours: 24,
      now: DateTime.fromMillisecondsSinceEpoch(1767268805000),
    );
    expect(event.store, isTrue);

    final restored = WireEvent.fromQueueJson(event.toQueueJson());
    expect(restored.toPublishJson(), event.toPublishJson());

    final ctx = EventContext(groupId: 'group-1', deviceId: restored.deviceId, eventId: restored.eventId, epoch: restored.epoch);
    final back = c.decryptLocation(key, ctx, restored.payload);
    expect(back.ts, point.ts);
    expect(back.lat, closeTo(point.lat, 1e-5));
    expect(back.lon, closeTo(point.lon, 1e-5));

    // The same point survives the message sent from the service to the app.
    expect(LocationPoint.fromJson(point.toJson()).lat, point.lat);
  });

  test('live-only events are not stored', () async {
    final c = OlCrypto(await SodiumSumoInit.init());
    final me = c.createIdentity();
    final event = buildLocationEvent(
      c,
      groupId: 'g',
      deviceId: me.deviceId,
      epoch: 1,
      locationKey: c.newLocationKey(),
      point: LocationPoint(ts: 1767268800, lat: 1, lon: 2),
      retentionHours: 0,
      now: DateTime.fromMillisecondsSinceEpoch(1767268805000),
    );
    expect(event.store, isFalse);
    expect(event.expiresAt, 1767268805000 + 60000);
  });
}
