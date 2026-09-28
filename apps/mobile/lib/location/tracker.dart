import 'dart:async';

import 'package:geolocator/geolocator.dart';

enum BatteryMode {
  maximum('Maximum accuracy', 'GPS, every update'),
  balanced('Balanced', 'Wi-Fi/cell + GPS, updates after ~25 m of movement'),
  saver('Battery saver', 'Low power, updates after ~250 m of movement');

  const BatteryMode(this.label, this.description);

  final String label;
  final String description;
}

/// Thin wrapper over the OS location service. On Android it runs as a foreground service with a
/// visible notification, so tracking continues with the screen off — no background hacks.
/// The interval is a *desired* interval: the OS may deliver updates later (Doze, no movement).
class Tracker {
  StreamSubscription<Position>? _sub;

  bool get running => _sub != null;

  /// Returns a user-facing problem, or null if location can be used.
  Future<String?> ensurePermission() async {
    if (!await Geolocator.isLocationServiceEnabled()) return 'Turn on location services to share your location.';
    var p = await Geolocator.checkPermission();
    if (p == LocationPermission.denied) p = await Geolocator.requestPermission();
    if (p == LocationPermission.denied) return 'Location permission is needed to share your location.';
    if (p == LocationPermission.deniedForever) return 'Location permission is blocked. Enable it in the system settings.';
    return null;
  }

  Future<void> start({
    required int intervalSeconds,
    required BatteryMode mode,
    required String notificationText,
    required void Function(Position) onPosition,
  }) async {
    await stop();
    final settings = AndroidSettings(
      accuracy: switch (mode) {
        BatteryMode.maximum => LocationAccuracy.high,
        BatteryMode.balanced => LocationAccuracy.medium,
        BatteryMode.saver => LocationAccuracy.low,
      },
      distanceFilter: switch (mode) {
        BatteryMode.maximum => 0,
        BatteryMode.balanced => 25,
        BatteryMode.saver => 250,
      },
      intervalDuration: Duration(seconds: intervalSeconds),
      foregroundNotificationConfig: ForegroundNotificationConfig(
        notificationTitle: 'OpenLocate is sharing your location',
        notificationText: notificationText,
        notificationChannelName: 'Location sharing',
        setOngoing: true,
      ),
    );
    _sub = Geolocator.getPositionStream(locationSettings: settings).listen(onPosition, onError: (_) {});
  }

  Future<void> stop() async {
    await _sub?.cancel();
    _sub = null;
  }

  static Future<Position?> currentPosition() async {
    try {
      final p = await Geolocator.checkPermission();
      if (p == LocationPermission.denied || p == LocationPermission.deniedForever) return null;
      return await Geolocator.getLastKnownPosition() ??
          await Geolocator.getCurrentPosition(locationSettings: const LocationSettings(accuracy: LocationAccuracy.medium));
    } catch (_) {
      return null;
    }
  }
}
