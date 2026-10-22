import 'dart:io';

import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:geolocator/geolocator.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sodium/sodium_sumo.dart';

import '../crypto/ol_crypto.dart';
import 'sharing_engine.dart';
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

/// The app's handle on sharing (see sharing_engine.dart).
///
/// Android: tracking, encryption and upload run in a foreground service with its own isolate
/// (sharing_service.dart), so sharing continues when the app's screen is closed; this class
/// starts, stops and talks to that service.
///
/// iOS has no such service. The engine runs inside the app, and iOS keeps delivering positions
/// in the background (with the blue location indicator) because the request allows background
/// updates and the app declares the `location` background mode.
class Tracker implements SharingHost {
  static const _serviceId = 4711;
  static const notificationTitle = 'OpenLocate is sharing your location';

  static final bool _inApp = Platform.isIOS;
  SharingEngine? _engine;
  final _listeners = <void Function(Object data)>[];

  /// Must be called once before `runApp`, so messages from the service can be received.
  static void initPort() {
    if (!_inApp) FlutterForegroundTask.initCommunicationPort();
  }

  Future<bool> get running async => _inApp ? _engine != null : await FlutterForegroundTask.isRunningService;

  void listen(void Function(Object data) onData) =>
      _inApp ? _listeners.add(onData) : FlutterForegroundTask.addTaskDataCallback(onData);

  void unlisten(void Function(Object data) onData) =>
      _inApp ? _listeners.remove(onData) : FlutterForegroundTask.removeTaskDataCallback(onData);

  // SharingHost, used only when the engine runs in the app (iOS).
  @override
  void send(Map<String, Object?> message) {
    for (final l in List.of(_listeners)) {
      l(message);
    }
  }

  @override
  void showStatus(String title, String text) {} // iOS shows its own location indicator

  @override
  Future<void> stop() async {
    final engine = _engine;
    _engine = null;
    await engine?.dispose();
  }

  /// Returns a user-facing problem, or null if location can be used.
  Future<String?> ensurePermission() async {
    if (!await Geolocator.isLocationServiceEnabled()) return 'Turn on location services to share your location.';
    var p = await Geolocator.checkPermission();
    if (p == LocationPermission.denied) p = await Geolocator.requestPermission();
    if (p == LocationPermission.denied) return 'Location permission is needed to share your location.';
    if (p == LocationPermission.deniedForever) return 'Location permission is blocked. Enable it in the system settings.';
    // Android 13+ hides the "sharing" notification without this; sharing still works if refused.
    if (!_inApp && await FlutterForegroundTask.checkNotificationPermission() != NotificationPermission.granted) {
      await FlutterForegroundTask.requestNotificationPermission();
    }
    return null;
  }

  /// Starts the service, replacing a running one. Returns a problem description, or null.
  Future<String?> start({required BatteryMode mode, required String notificationText, required bool restartOnBoot}) async {
    if (_inApp) {
      await stop();
      try {
        _engine = SharingEngine(OlCrypto(await SodiumSumoInit.init()), this);
      } catch (e) {
        return '$e';
      }
      await _engine!.start();
      return null;
    }
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

  Future<void> stopSharing() async {
    if (_inApp) return stop();
    if (await running) await FlutterForegroundTask.stopService();
  }

  void _toService(Map<String, Object?> message) =>
      _inApp ? _engine?.receive(message) : FlutterForegroundTask.sendDataToTask(message);

  /// Tells the service that keys or preferences changed.
  void reload() => _toService({'type': 'reload'});

  /// Asks the service to try delivering queued fixes now (for example after reconnecting).
  void flush() => _toService({'type': 'flush'});

  /// Asks the service to report its queue length and any problem.
  void requestStatus() => _toService({'type': 'status'});

  /// Deletes fixes that were never delivered. Only call while the service is stopped.
  Future<void> clearQueue() async {
    final f = await pendingQueueFile();
    if (await f.exists()) await f.delete();
  }

  /// Android only; iOS has no per-app battery optimisation to opt out of.
  Future<bool> get batteryExempt async => _inApp || await FlutterForegroundTask.isIgnoringBatteryOptimizations;

  Future<void> requestBatteryExemption() async {
    if (!_inApp) await FlutterForegroundTask.requestIgnoreBatteryOptimization();
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
