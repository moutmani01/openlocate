import 'dart:io';

import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:geolocator/geolocator.dart';
import 'package:path_provider/path_provider.dart';

import 'sharing_service.dart';

enum BatteryMode {
  maximum('Maximum accuracy', 'GPS, every update'),
  balanced('Balanced', 'Wi-Fi/cell + GPS, updates after ~25 m of movement'),
  saver('Battery saver', 'Low power, updates after ~250 m of movement');

  const BatteryMode(this.label, this.description);

  final String label;
  final String description;
}

/// File holding encrypted fixes that have not reached the server yet.
Future<File> pendingQueueFile() async => File('${(await getApplicationSupportDirectory()).path}/pending_events.jsonl');

/// The app's handle on the background sharing service (see sharing_service.dart).
///
/// Tracking, encryption and upload run in an Android foreground service with its own isolate,
/// so sharing continues when the app's screen is closed. This class only starts, stops and
/// talks to that service; it never touches location itself except for the one-off map position.
class Tracker {
  static const _serviceId = 4711;
  static const notificationTitle = 'OpenLocate is sharing your location';

  /// Must be called once before `runApp`, so messages from the service can be received.
  static void initPort() => FlutterForegroundTask.initCommunicationPort();

  Future<bool> get running => FlutterForegroundTask.isRunningService;

  void listen(void Function(Object data) onData) => FlutterForegroundTask.addTaskDataCallback(onData);

  void unlisten(void Function(Object data) onData) => FlutterForegroundTask.removeTaskDataCallback(onData);

  /// Returns a user-facing problem, or null if location can be used.
  Future<String?> ensurePermission() async {
    if (!await Geolocator.isLocationServiceEnabled()) return 'Turn on location services to share your location.';
    var p = await Geolocator.checkPermission();
    if (p == LocationPermission.denied) p = await Geolocator.requestPermission();
    if (p == LocationPermission.denied) return 'Location permission is needed to share your location.';
    if (p == LocationPermission.deniedForever) return 'Location permission is blocked. Enable it in the system settings.';
    // Android 13+ hides the "sharing" notification without this; sharing still works if refused.
    if (await FlutterForegroundTask.checkNotificationPermission() != NotificationPermission.granted) {
      await FlutterForegroundTask.requestNotificationPermission();
    }
    return null;
  }

  /// Starts the service, replacing a running one. Returns a problem description, or null.
  Future<String?> start({required BatteryMode mode, required String notificationText, required bool restartOnBoot}) async {
    FlutterForegroundTask.init(
      androidNotificationOptions: AndroidNotificationOptions(
        channelId: 'location_sharing',
        channelName: 'Location sharing',
        channelDescription: 'Shown while OpenLocate is sharing your location.',
        channelImportance: NotificationChannelImportance.LOW,
        priority: NotificationPriority.LOW,
        onlyAlertOnce: true,
      ),
      iosNotificationOptions: const IOSNotificationOptions(showNotification: false, playSound: false),
      foregroundTaskOptions: ForegroundTaskOptions(
        // No periodic wake-ups: the service only runs when the OS delivers a location.
        eventAction: ForegroundTaskEventAction.nothing(),
        autoRunOnBoot: restartOnBoot,
        autoRunOnMyPackageReplaced: restartOnBoot,
        // Keeping the CPU awake costs battery; only "Maximum accuracy" pays for it.
        allowWakeLock: mode == BatteryMode.maximum,
        allowWifiLock: false,
        allowAutoRestart: true,
      ),
    );
    if (await running) await FlutterForegroundTask.stopService();
    final result = await FlutterForegroundTask.startService(
      serviceId: _serviceId,
      serviceTypes: [ForegroundServiceTypes.location],
      notificationTitle: notificationTitle,
      notificationText: notificationText,
      notificationButtons: const [NotificationButton(id: stopButtonId, text: 'Stop sharing')],
      callback: sharingServiceMain,
    );
    return result is ServiceRequestFailure ? '${result.error}' : null;
  }

  Future<void> stop() async {
    if (await running) await FlutterForegroundTask.stopService();
  }

  /// Tells the service that keys or preferences changed.
  void reload() => FlutterForegroundTask.sendDataToTask({'type': 'reload'});

  /// Asks the service to try delivering queued fixes now (for example after reconnecting).
  void flush() => FlutterForegroundTask.sendDataToTask({'type': 'flush'});

  /// Asks the service to report its queue length and any problem.
  void requestStatus() => FlutterForegroundTask.sendDataToTask({'type': 'status'});

  /// Deletes fixes that were never delivered. Only call while the service is stopped.
  Future<void> clearQueue() async {
    final f = await pendingQueueFile();
    if (await f.exists()) await f.delete();
  }

  Future<bool> get batteryExempt => FlutterForegroundTask.isIgnoringBatteryOptimizations;

  Future<void> requestBatteryExemption() => FlutterForegroundTask.requestIgnoreBatteryOptimization();

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
