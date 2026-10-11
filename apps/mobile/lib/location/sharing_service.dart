import 'dart:async';
import 'dart:math';

import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:geolocator/geolocator.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sodium/sodium_sumo.dart';

import '../backend/backend_provider.dart';
import '../backend/http_provider.dart';
import '../config.dart';
import '../crypto/ol_crypto.dart';
import '../format.dart';
import 'disk_queue.dart';
import 'fix_builder.dart';
import 'sharing_config.dart';
import 'tracker.dart';

const stopButtonId = 'stop';

/// Entry point of the background isolate. Android starts it inside the foreground service.
@pragma('vm:entry-point')
void sharingServiceMain() {
  FlutterForegroundTask.setTaskHandler(SharingTaskHandler());
}

/// Shares location while the app's screen is closed.
///
/// Built to do as little as possible between fixes: there is no timer and no open connection.
/// The service wakes only when the OS delivers a location, encrypts it, appends it to the
/// on-disk queue and sends the queue with one HTTPS request. If that fails, a single retry timer
/// runs with a growing delay until the queue is empty again.
class SharingTaskHandler extends TaskHandler {
  OlCrypto? _crypto;
  SharingConfig? _config;
  BackendProvider? _backend;
  DiskQueue? _queue;
  StreamSubscription<Position>? _positions;
  StreamSubscription<ServiceStatus>? _locationSwitch;
  Timer? _retry;
  int _retryDelay = _firstRetry;
  DateTime? _lastSent;
  bool _flushing = false;
  String? _problem;

  static const _firstRetry = 30;
  static const _maxRetry = 900;
  static const _batch = 200;

  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {
    try {
      _crypto = OlCrypto(await SodiumSumoInit.init());
      _queue = DiskQueue(await pendingQueueFile(), maxItems: AppConfig.maxQueue);
      await _queue!.load();
      await _reload();
      // If location is switched off and on again, resume without the app being opened.
      _locationSwitch = Geolocator.getServiceStatusStream().listen(
        (status) {
          if (status == ServiceStatus.enabled && _positions == null) _listen();
        },
        onError: (_) {},
      );
      unawaited(_flush());
    } catch (_) {
      _setProblem('Sharing could not start. Open OpenLocate to try again.');
    }
  }

  @override
  void onRepeatEvent(DateTime timestamp) {}

  @override
  Future<void> onDestroy(DateTime timestamp, bool isTimeout) async {
    _retry?.cancel();
    await _positions?.cancel();
    await _locationSwitch?.cancel();
  }

  @override
  void onReceiveData(Object data) {
    if (data is! Map) return;
    switch (data['type']) {
      case 'reload':
        unawaited(_reload());
      case 'flush':
        unawaited(_flush());
      case 'status':
        _report();
    }
  }

  @override
  void onNotificationButtonPressed(String id) {
    if (id == stopButtonId) unawaited(_stopSharing(byUser: true));
  }

  /// Reads keys and preferences again and restarts the location stream with them.
  Future<void> _reload() async {
    final config = await SharingConfig.load(_crypto!);
    if (config == null) {
      await _stopSharing(byUser: false);
      return;
    }
    _config = config;
    _backend = HttpProvider(config.backendUrl, _crypto!, config.identity);
    _listen();
    _showStatus();
  }

  void _listen() {
    final config = _config;
    if (config == null) return;
    unawaited(_positions?.cancel());
    final settings = AndroidSettings(
      accuracy: switch (config.mode) {
        BatteryMode.maximum => LocationAccuracy.high,
        BatteryMode.balanced => LocationAccuracy.medium,
        BatteryMode.saver => LocationAccuracy.low,
      },
      distanceFilter: switch (config.mode) {
        BatteryMode.maximum => 0,
        BatteryMode.balanced => 25,
        BatteryMode.saver => 250,
      },
      intervalDuration: Duration(seconds: config.intervalSeconds),
    );
    _positions = Geolocator.getPositionStream(locationSettings: settings).listen(
      (p) => unawaited(_onPosition(p)),
      onError: _onLocationError,
    );
  }

  void _onLocationError(Object error) {
    if (error is LocationServiceDisabledException) {
      _setProblem('Paused: location is turned off on this phone.');
    } else if (error is PermissionDeniedException) {
      _setProblem('Paused: location permission was removed.');
    } else {
      return;
    }
    unawaited(_positions?.cancel());
    _positions = null;
  }

  Future<void> _onPosition(Position pos) async {
    final config = _config;
    if (config == null) return;
    if (_problem != null) _setProblem(null);
    final now = DateTime.now();
    if (!shouldSend(_lastSent, now, config.intervalSeconds)) return;
    final previous = _lastSent;
    _lastSent = now;

    final point = LocationPoint(
      ts: pos.timestamp.millisecondsSinceEpoch ~/ 1000,
      lat: pos.latitude,
      lon: pos.longitude,
      acc: pos.accuracy,
      spd: pos.speed > 0 ? pos.speed : null,
      hdg: pos.speed > 0.5 ? pos.heading : null,
    );
    try {
      final event = buildLocationEvent(
        _crypto!,
        groupId: config.groupId,
        deviceId: config.identity.deviceId,
        epoch: config.epoch,
        locationKey: config.locationKey,
        point: point,
        retentionHours: config.retentionHours,
        now: now,
      );
      await _queue!.add(event.toQueueJson());
    } catch (_) {
      return; // Never let one bad fix stop the stream.
    }
    final sinceLast = previous == null ? null : now.difference(previous).inSeconds;
    FlutterForegroundTask.sendDataToMain({'type': 'fix', 'point': point.toJson(), 'since_last_s': ?sinceLast});
    await _flush();
  }

  /// Sends queued events, oldest first. Events stay on disk until the server has accepted them.
  Future<void> _flush() async {
    final queue = _queue, backend = _backend, config = _config;
    if (_flushing || queue == null || backend == null || config == null || queue.isEmpty) {
      _report();
      return;
    }
    _flushing = true;
    try {
      while (!queue.isEmpty) {
        final batch = queue.peek(_batch);
        final nowMs = DateTime.now().millisecondsSinceEpoch;
        // The server would discard expired events anyway; do not spend data sending them.
        final live = batch.map(WireEvent.fromQueueJson).where((e) => e.expiresAt == null || e.expiresAt! > nowMs).toList();
        try {
          if (live.isNotEmpty) await backend.publish(config.groupId, live);
        } on BackendException catch (e) {
          // 400/413 mean this batch can never be accepted: drop it so it cannot block the queue.
          if (e.status != 400 && e.status != 413) rethrow;
        }
        await queue.removeFirst(batch.length);
      }
      _retry?.cancel();
      _retry = null;
      _retryDelay = _firstRetry;
    } on BackendException catch (e) {
      if (e.status == 403 || e.status == 404) {
        // Removed from the group, or the group is gone: nothing more can be delivered.
        _flushing = false;
        await _stopSharing(byUser: false, reason: 'Sharing stopped: this phone is no longer in the group.');
        return;
      }
      _scheduleRetry();
    } catch (_) {
      _scheduleRetry();
    } finally {
      _flushing = false;
    }
    _report();
  }

  void _scheduleRetry() {
    if (_retry != null) return;
    _retry = Timer(Duration(seconds: _retryDelay), () {
      _retry = null;
      unawaited(_flush());
    });
    _retryDelay = min(_retryDelay * 2, _maxRetry);
  }

  Future<void> _stopSharing({required bool byUser, String? reason}) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool('sharing_active', false);
    } catch (_) {}
    FlutterForegroundTask.sendDataToMain({'type': 'stopped', 'by_user': byUser, 'reason': ?reason});
    await FlutterForegroundTask.stopService();
  }

  void _setProblem(String? problem) {
    if (_problem == problem) return;
    _problem = problem;
    _showStatus();
    _report();
  }

  /// The ongoing notification doubles as the status display while the app is closed.
  void _showStatus() {
    final config = _config;
    final problem = _problem;
    unawaited(FlutterForegroundTask.updateService(
      notificationTitle: problem == null ? Tracker.notificationTitle : 'OpenLocate sharing is paused',
      notificationText: problem ?? (config == null ? '' : sharingNotificationText(config.people, config.intervalSeconds)),
    ));
  }

  void _report() {
    FlutterForegroundTask.sendDataToMain({'type': 'status', 'queued': _queue?.length ?? 0, 'problem': ?_problem});
  }
}
