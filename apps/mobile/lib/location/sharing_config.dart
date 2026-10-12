import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../crypto/ol_crypto.dart';
import 'tracker.dart';

/// Everything the background service needs to share location, read from the same storage the
/// app writes: keys from the OS secure storage, preferences from SharedPreferences.
class SharingConfig {
  SharingConfig({
    required this.identity,
    required this.groupId,
    required this.backendUrl,
    required this.epoch,
    required this.locationKey,
    required this.people,
    required this.intervalSeconds,
    required this.mode,
    required this.retentionHours,
  });

  final Identity identity;
  final String groupId;
  final String backendUrl;
  final int epoch;
  final Uint8List locationKey;

  /// How many people can currently see this device.
  final int people;
  final int intervalSeconds;
  final BatteryMode mode;
  final int retentionHours;

  /// Returns null when the device is not in a group (nothing to share).
  static Future<SharingConfig?> load(OlCrypto crypto) async {
    const secure = FlutterSecureStorage();
    final identity = await secure.read(key: 'identity');
    final group = await secure.read(key: 'group');
    final sharing = await secure.read(key: 'sharing');
    if (identity == null || group == null || sharing == null) return null;

    // The app may have changed preferences from another isolate since this one read them.
    final prefs = await SharedPreferences.getInstance();
    await prefs.reload();

    final g = jsonDecode(group) as Map<String, dynamic>;
    final s = jsonDecode(sharing) as Map<String, dynamic>;
    return SharingConfig(
      identity: crypto.importIdentity(identity),
      groupId: g['group_id'] as String,
      backendUrl: g['backend'] as String,
      epoch: s['epoch'] as int,
      locationKey: unb64url(s['key'] as String),
      people: (s['share_with'] as List).length,
      intervalSeconds: prefs.getInt('interval_s') ?? 60,
      mode: BatteryMode.values.byName(prefs.getString('mode') ?? BatteryMode.balanced.name),
      retentionHours: prefs.getInt('retention_h') ?? 24,
    );
  }
}
