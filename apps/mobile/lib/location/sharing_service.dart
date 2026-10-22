import 'dart:async';

import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:sodium/sodium_sumo.dart';

import '../crypto/ol_crypto.dart';
import 'sharing_engine.dart';

const stopButtonId = 'stop';

/// Entry point of the background isolate. Android starts it inside the foreground service.
@pragma('vm:entry-point')
void sharingServiceMain() {
  FlutterForegroundTask.setTaskHandler(SharingTaskHandler());
}

/// Android: runs the [SharingEngine] inside a foreground service with its own isolate, so sharing
/// continues when the app's screen is closed. The ongoing notification doubles as the status
/// display.
class SharingTaskHandler extends TaskHandler implements SharingHost {
  SharingEngine? _engine;

  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {
    try {
      _engine = SharingEngine(OlCrypto(await SodiumSumoInit.init()), this);
    } catch (_) {
      showStatus('OpenLocate sharing is paused', 'Sharing could not start. Open OpenLocate to try again.');
      return;
    }
    await _engine!.start();
  }

  @override
  void onRepeatEvent(DateTime timestamp) {}

  @override
  Future<void> onDestroy(DateTime timestamp, bool isTimeout) async => _engine?.dispose();

  @override
  void onReceiveData(Object data) => _engine?.receive(data);

  @override
  void onNotificationButtonPressed(String id) {
    if (id == stopButtonId) unawaited(_engine?.stopSharing(byUser: true));
  }

  @override
  void send(Map<String, Object?> message) => FlutterForegroundTask.sendDataToMain(message);

  @override
  void showStatus(String title, String text) =>
      unawaited(FlutterForegroundTask.updateService(notificationTitle: title, notificationText: text));

  @override
  Future<void> stop() async => FlutterForegroundTask.stopService();
}
