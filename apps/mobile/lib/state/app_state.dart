import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:geolocator/geolocator.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../backend/backend_provider.dart';
import '../backend/http_provider.dart';
import '../config.dart';
import '../crypto/ol_crypto.dart';
import '../location/tracker.dart';

class Peer {
  Peer({required this.deviceId, required this.name, required this.sharesWithMe});

  final String deviceId;
  final String name;
  final bool sharesWithMe;
}

class Fix {
  Fix(this.point, this.receivedAt);

  final LocationPoint point;
  final DateTime receivedAt;

  DateTime get time => DateTime.fromMillisecondsSinceEpoch(point.ts * 1000);
}

/// Everything the UI needs. Persisted: identity/keys in OS secure storage, preferences in
/// SharedPreferences. Locations are kept in memory only in this beta (server keeps history).
class AppState extends ChangeNotifier {
  AppState(this.crypto);

  final OlCrypto crypto;
  final _secure = const FlutterSecureStorage();
  late SharedPreferences _prefs;
  late Identity identity;
  final tracker = Tracker();

  // Preferences
  String displayName = '';
  String backendUrl = AppConfig.backendUrl;
  int intervalSeconds = 60;
  BatteryMode mode = BatteryMode.balanced;
  int retentionHours = 24;
  bool sharingActive = false;

  // Group
  String? groupId;
  String? groupName;
  BackendProvider? _backend;
  GroupState? group;

  // Outgoing sharing state (sender key)
  int _epoch = 1;
  Uint8List _locationKey = Uint8List(0);
  final Map<int, Uint8List> _ownKeys = {};
  Set<String> shareWith = {};

  // Incoming
  final Map<String, Peer> peers = {};
  final Map<String, Map<int, Uint8List>> _keys = {};
  final Map<String, List<Fix>> history = {};
  final Set<String> online = {};
  final Set<String> unverified = {};
  final Map<String, String> _invites = {};
  int _historyCursor = 0;

  // Live connection
  LiveConnection? _live;
  bool connected = false;
  Timer? _reconnect;
  int _backoff = 2;
  final List<WireEvent> _queue = [];

  // Tracking stats
  Position? myPosition;
  DateTime? _lastSent;
  final List<int> _intervals = [];
  String? error;

  String get myId => identity.deviceId;
  bool get inGroup => groupId != null;
  int get queued => _queue.length;
  String get safetyNumber => crypto.safetyNumber(identity.signPk);

  /// Average of the last few actual intervals between sent fixes, in seconds.
  double? get actualInterval => _intervals.isEmpty ? null : _intervals.reduce((a, b) => a + b) / _intervals.length;

  List<GroupMember> get others => group?.members.where((m) => m.deviceId != myId).toList() ?? [];

  String nameOf(String deviceId) => deviceId == myId ? displayName : peers[deviceId]?.name ?? 'Member ${deviceId.substring(0, 4)}';

  Fix? latestOf(String deviceId) {
    final h = history[deviceId];
    return h == null || h.isEmpty ? null : h.last;
  }

  // ------------------------------------------------------------------ startup

  Future<void> init() async {
    _prefs = await SharedPreferences.getInstance();
    final stored = await _secure.read(key: 'identity');
    if (stored == null) {
      identity = crypto.createIdentity();
      await _secure.write(key: 'identity', value: crypto.exportIdentity(identity));
    } else {
      identity = crypto.importIdentity(stored);
    }
    displayName = _prefs.getString('display_name') ?? '';
    backendUrl = _prefs.getString('backend_url') ?? AppConfig.backendUrl;
    intervalSeconds = _prefs.getInt('interval_s') ?? 60;
    mode = BatteryMode.values.byName(_prefs.getString('mode') ?? BatteryMode.balanced.name);
    retentionHours = _prefs.getInt('retention_h') ?? 24;

    final g = await _secure.read(key: 'group');
    if (g != null) {
      final j = jsonDecode(g) as Map<String, dynamic>;
      groupId = j['group_id'] as String;
      groupName = j['name'] as String?;
      backendUrl = j['backend'] as String;
      _loadSharing(await _secure.read(key: 'sharing'));
      final inv = await _secure.read(key: 'invites');
      if (inv != null) _invites.addAll((jsonDecode(inv) as Map).cast<String, String>());
      _backend = HttpProvider(backendUrl, crypto, identity);
      unawaited(_connectAndSync());
      if (_prefs.getBool('sharing_active') ?? false) unawaited(setSharingActive(true));
    }
  }

  void _loadSharing(String? json) {
    if (json == null) {
      _newSharing();
      return;
    }
    final j = jsonDecode(json) as Map<String, dynamic>;
    _epoch = j['epoch'] as int;
    _locationKey = unb64url(j['key'] as String);
    shareWith = (j['share_with'] as List).cast<String>().toSet();
    (j['old_keys'] as Map? ?? {}).forEach((k, v) => _ownKeys[int.parse(k as String)] = unb64url(v as String));
    _ownKeys[_epoch] = _locationKey;
  }

  void _newSharing() {
    _epoch = 1;
    _locationKey = crypto.newLocationKey();
    _ownKeys
      ..clear()
      ..[_epoch] = _locationKey;
    shareWith = {};
  }

  Future<void> _saveSharing() async {
    final recent = _ownKeys.keys.toList()..sort();
    final keep = recent.length > 20 ? recent.sublist(recent.length - 20) : recent;
    await _secure.write(
      key: 'sharing',
      value: jsonEncode({
        'epoch': _epoch,
        'key': b64url(_locationKey),
        'share_with': shareWith.toList(),
        'old_keys': {for (final e in keep) '$e': b64url(_ownKeys[e]!)},
      }),
    );
  }

  Future<void> _saveGroup() async {
    await _secure.write(key: 'group', value: jsonEncode({'group_id': groupId, 'name': groupName, 'backend': backendUrl}));
  }

  // ------------------------------------------------------------------ preferences

  Future<void> setDisplayName(String name) async {
    displayName = name.trim();
    await _prefs.setString('display_name', displayName);
    notifyListeners();
    if (inGroup) await _publishCards();
  }

  Future<void> setBackendUrl(String url) async {
    backendUrl = url.trim().replaceAll(RegExp(r'/+$'), '');
    await _prefs.setString('backend_url', backendUrl);
    notifyListeners();
  }

  Future<void> setInterval(int seconds) async {
    intervalSeconds = max(5, seconds);
    _intervals.clear();
    await _prefs.setInt('interval_s', intervalSeconds);
    await _restartTracking();
  }

  Future<void> setMode(BatteryMode m) async {
    mode = m;
    await _prefs.setString('mode', m.name);
    await _restartTracking();
  }

  Future<void> setRetention(int hours) async {
    retentionHours = hours;
    await _prefs.setInt('retention_h', hours);
    notifyListeners();
  }

  // ------------------------------------------------------------------ group lifecycle

  Future<void> createGroup(String name) async {
    _requireBackendUrl();
    final gid = b64url(crypto.sodium.randombytes.buf(16));
    final backend = HttpProvider(backendUrl, crypto, identity);
    group = await backend.createGroup(gid);
    _backend = backend;
    groupId = gid;
    groupName = name.trim().isEmpty ? 'My group' : name.trim();
    _newSharing();
    await _saveGroup();
    await _saveSharing();
    notifyListeners();
    unawaited(_connectAndSync());
  }

  Future<void> joinWithLink(String link) async {
    final inv = InviteLink.decode(link);
    if (inv.expiresAt < DateTime.now().millisecondsSinceEpoch) throw const FormatException('This invitation has expired');
    final derived = crypto.deriveInvite(inv.secret);
    final backend = HttpProvider(inv.backend, crypto, identity);
    final keys = crypto.memberKeys(identity);
    final state = await backend.joinGroup(
      inv.groupId,
      inviteId: derived.inviteId,
      authKey: b64url(derived.authKey),
      member: keys,
      binding: crypto.joinBinding(derived, inv.groupId, keys),
    );
    // The inviter's id came from the QR code, not from the server: make sure it's really there.
    if (!state.members.any((m) => m.deviceId == inv.inviter && crypto.verifyMemberKeys(m.keys))) {
      throw const FormatException('The group does not contain the person who invited you');
    }
    _backend = backend;
    backendUrl = inv.backend;
    groupId = inv.groupId;
    groupName = inv.name ?? 'Shared group';
    group = state;
    _newSharing();
    await _saveGroup();
    await _saveSharing();
    notifyListeners();
    await _publishCards();
    unawaited(_connectAndSync());
  }

  /// Creates a single-use invitation valid for 10 minutes and returns the QR/link text.
  Future<String> createInviteLink() async {
    final inv = crypto.newInvite();
    final expires = DateTime.now().add(const Duration(minutes: 10)).millisecondsSinceEpoch;
    await _backend!.createInvitation(groupId!, inviteId: inv.inviteId, authHash: inv.authHash, expiresAt: expires);
    _invites[inv.inviteId] = b64url(inv.secret);
    await _secure.write(key: 'invites', value: jsonEncode(_invites));
    return InviteLink(backend: backendUrl, groupId: groupId!, secret: inv.secret, inviter: myId, expiresAt: expires, name: groupName).encode();
  }

  Future<void> leaveGroup() async {
    await setSharingActive(false);
    try {
      await _backend?.removeMember(groupId!, myId);
    } catch (_) {
      // Leave locally even if the server is unreachable.
    }
    await _live?.close();
    _reconnect?.cancel();
    _live = null;
    connected = false;
    groupId = null;
    groupName = null;
    group = null;
    _backend = null;
    peers.clear();
    _keys.clear();
    history.clear();
    online.clear();
    unverified.clear();
    _queue.clear();
    _invites.clear();
    _historyCursor = 0;
    await _secure.delete(key: 'group');
    await _secure.delete(key: 'sharing');
    await _secure.delete(key: 'invites');
    notifyListeners();
  }

  Future<void> removeMember(String deviceId) async {
    await _backend!.removeMember(groupId!, deviceId);
    await refresh();
  }

  Future<void> deleteMyHistory() async {
    await _backend!.deleteHistory(groupId!);
    history.remove(myId);
    notifyListeners();
  }

  void _requireBackendUrl() {
    if (backendUrl.isEmpty) throw const FormatException('Set a server address in Settings first');
  }

  // ------------------------------------------------------------------ sharing

  /// Grant or revoke one person's access. Revoking rotates the key so they can't read what comes next.
  Future<void> setShareWith(String deviceId, bool share) async {
    if (share) {
      shareWith.add(deviceId);
    } else if (shareWith.remove(deviceId)) {
      _rotateKey();
    }
    await _saveSharing();
    notifyListeners();
    await _publishCards();
  }

  void _rotateKey() {
    _epoch += 1;
    _locationKey = crypto.newLocationKey();
    _ownKeys[_epoch] = _locationKey;
  }

  Future<void> _publishCards() async {
    final g = group;
    if (g == null || _backend == null) return;
    for (final m in g.members) {
      if (m.deviceId == myId || !crypto.verifyMemberKeys(m.keys)) continue;
      final shares = shareWith.contains(m.deviceId);
      final envelope = crypto.sealCard(identity, m.keys, {
        'v': 1,
        'group_id': g.groupId,
        'from': myId,
        'to': m.deviceId,
        'epoch': _epoch,
        'issued_at': DateTime.now().millisecondsSinceEpoch,
        'display_name': displayName,
        if (shares) 'location_key': b64url(_locationKey),
      });
      try {
        await _backend!.putCard(g.groupId, m.deviceId, envelope: envelope, epoch: _epoch, sharesLocation: shares);
      } catch (e) {
        error = 'Could not update sharing: $e';
      }
    }
  }

  Future<void> setSharingActive(bool on) async {
    if (on) {
      final problem = await tracker.ensurePermission();
      if (problem != null) {
        error = problem;
        notifyListeners();
        return;
      }
    }
    sharingActive = on;
    await _prefs.setBool('sharing_active', on);
    await _restartTracking();
  }

  Future<void> _restartTracking() async {
    await tracker.stop();
    if (sharingActive && inGroup) {
      final n = shareWith.length;
      await tracker.start(
        intervalSeconds: intervalSeconds,
        mode: mode,
        notificationText: 'Visible to $n ${n == 1 ? 'person' : 'people'} · every ${formatInterval(intervalSeconds)}',
        onPosition: _onPosition,
      );
    }
    notifyListeners();
  }

  void _onPosition(Position pos) {
    myPosition = pos;
    final now = DateTime.now();
    // The OS may deliver more often than asked; send at most once per desired interval.
    if (_lastSent != null && now.difference(_lastSent!).inMilliseconds < intervalSeconds * 900) {
      notifyListeners();
      return;
    }
    if (_lastSent != null) {
      _intervals.add(now.difference(_lastSent!).inSeconds);
      if (_intervals.length > 10) _intervals.removeAt(0);
    }
    _lastSent = now;

    final point = LocationPoint(
      ts: pos.timestamp.millisecondsSinceEpoch ~/ 1000,
      lat: pos.latitude,
      lon: pos.longitude,
      acc: pos.accuracy,
      spd: pos.speed > 0 ? pos.speed : null,
      hdg: pos.speed > 0.5 ? pos.heading : null,
    );
    final eventId = crypto.newEventId(myId);
    final ctx = EventContext(groupId: groupId!, deviceId: myId, eventId: eventId, epoch: _epoch);
    final retentionMs = retentionHours * 3600 * 1000;
    final expires = retentionMs == 0
        ? now.millisecondsSinceEpoch + 60000
        : ((point.ts * 1000 + retentionMs) / 60000).ceil() * 60000; // rounded to the minute
    final e = WireEvent(
      deviceId: myId,
      eventId: eventId,
      epoch: _epoch,
      payload: crypto.encryptLocation(_locationKey, ctx, point),
      expiresAt: expires,
      store: retentionMs > 0,
    );
    _addFix(myId, point);
    if (connected && _live != null) {
      _live!.send({'type': 'publish', 'events': [e.toPublishJson()]});
    } else {
      _queue.add(e);
      if (_queue.length > AppConfig.maxQueue) _queue.removeAt(0);
    }
    notifyListeners();
  }

  // ------------------------------------------------------------------ sync

  Future<void> refresh() async {
    final b = _backend;
    if (b == null || groupId == null) return;
    final before = group?.members.map((m) => m.deviceId).toSet() ?? {};
    group = await b.getGroup(groupId!);
    final now = group!.members.map((m) => m.deviceId).toSet();

    // Anyone who left loses access: drop them and rotate if they could see us.
    final gone = shareWith.where((d) => !now.contains(d)).toList();
    if (gone.isNotEmpty) {
      shareWith.removeAll(gone);
      _rotateKey();
      await _saveSharing();
    }
    _verifyBindings();
    await _refreshCards();
    if (!setEquals(before, now) || gone.isNotEmpty) await _publishCards();
    await _fetchHistory();
    notifyListeners();
  }

  /// For people this device invited, check the server didn't swap their keys (see THREAT_MODEL.md).
  void _verifyBindings() {
    for (final m in group!.members) {
      if (m.invitedBy != myId || m.binding == null) continue;
      final ok = _invites.values.any((s) => crypto.verifyJoinBinding(crypto.deriveInvite(unb64url(s)), groupId!, m.keys, m.binding!));
      if (ok) {
        unverified.remove(m.deviceId);
      } else {
        unverified.add(m.deviceId);
      }
    }
  }

  Future<void> _refreshCards() async {
    final members = {for (final m in group!.members) m.deviceId: m};
    for (final rec in await _backend!.getCards(groupId!)) {
      final sender = members[rec.from];
      if (sender == null || !crypto.verifyMemberKeys(sender.keys)) continue;
      try {
        final c = crypto.openCard(identity, sender.keys, groupId!, rec.envelope);
        final key = c['location_key'] as String?;
        if (key != null) (_keys[rec.from] ??= {})[c['epoch'] as int] = unb64url(key);
        peers[rec.from] = Peer(deviceId: rec.from, name: (c['display_name'] as String?)?.trim().isNotEmpty == true ? c['display_name'] as String : 'Unnamed', sharesWithMe: key != null);
      } catch (_) {
        // Forged or corrupted card: ignore rather than trust the server.
      }
    }
    peers.removeWhere((id, _) => !members.containsKey(id));
  }

  LocationPoint? _decrypt(WireEvent e) {
    final key = e.deviceId == myId ? _ownKeys[e.epoch] : _keys[e.deviceId]?[e.epoch];
    if (key == null) return null;
    try {
      return crypto.decryptLocation(key, EventContext(groupId: groupId!, deviceId: e.deviceId, eventId: e.eventId, epoch: e.epoch), e.payload);
    } catch (_) {
      return null;
    }
  }

  Future<void> _fetchHistory() async {
    var more = true;
    var pages = 0;
    while (more && pages++ < 20) {
      final page = await _backend!.getHistory(groupId!, after: _historyCursor);
      for (final e in page.events) {
        final p = _decrypt(e);
        if (p != null) _addFix(e.deviceId, p);
      }
      _historyCursor = page.nextAfter;
      more = page.more;
    }
  }

  void _addFix(String deviceId, LocationPoint p) {
    final list = history[deviceId] ??= [];
    list.add(Fix(p, DateTime.now()));
    if (list.length > 1 && list[list.length - 2].point.ts > p.ts) list.sort((a, b) => a.point.ts.compareTo(b.point.ts));
    if (list.length > AppConfig.maxHistoryPerMember) list.removeRange(0, list.length - AppConfig.maxHistoryPerMember);
  }

  Future<void> _connectAndSync() async {
    _reconnect?.cancel();
    final b = _backend;
    if (b == null || groupId == null) return;
    try {
      await refresh();
      _live = await b.connect(groupId!, onMessage: _onMessage, onClosed: _onClosed);
      connected = true;
      _backoff = 2;
      error = null;
      await _flushQueue();
    } on BackendException catch (e) {
      error = e.status == 403 ? 'You are no longer a member of this group' : 'Server error: ${e.code}';
      _scheduleReconnect();
    } catch (e) {
      error = 'Offline — will retry';
      _scheduleReconnect();
    }
    notifyListeners();
  }

  Future<void> _flushQueue() async {
    while (_queue.isNotEmpty) {
      final batch = _queue.take(200).toList();
      await _backend!.publish(groupId!, batch);
      _queue.removeRange(0, batch.length);
    }
  }

  void _onClosed() {
    connected = false;
    _live = null;
    online.clear();
    notifyListeners();
    _scheduleReconnect();
  }

  void _scheduleReconnect() {
    if (groupId == null) return;
    _reconnect?.cancel();
    _reconnect = Timer(Duration(seconds: _backoff), _connectAndSync);
    _backoff = min(_backoff * 2, 120);
  }

  void _onMessage(Map<String, dynamic> m) {
    switch (m['type']) {
      case 'hello':
        online
          ..clear()
          ..addAll((m['online'] as List).cast<String>());
      case 'presence':
        final id = m['device_id'] as String;
        if (m['online'] == true) {
          online.add(id);
        } else {
          online.remove(id);
        }
      case 'event':
        final e = WireEvent.fromJson((m['event'] as Map).cast<String, dynamic>());
        final p = _decrypt(e);
        if (p != null) {
          _addFix(e.deviceId, p);
        } else {
          unawaited(refresh()); // probably a key rotation we haven't seen yet
        }
        if (e.seq != null && e.seq! > _historyCursor) _historyCursor = e.seq!;
      case 'member_joined':
      case 'member_left':
      case 'card_updated':
        unawaited(refresh());
      case 'error':
        error = 'Server: ${m['error']}';
    }
    notifyListeners();
  }

  @override
  void dispose() {
    _reconnect?.cancel();
    unawaited(tracker.stop());
    unawaited(_live?.close());
    super.dispose();
  }
}

String formatInterval(int s) {
  if (s < 60) return '$s s';
  if (s < 3600) return s % 60 == 0 ? '${s ~/ 60} min' : '${(s / 60).toStringAsFixed(1)} min';
  return s % 3600 == 0 ? '${s ~/ 3600} h' : '${(s / 3600).toStringAsFixed(1)} h';
}

String formatAgo(DateTime t) {
  final d = DateTime.now().difference(t);
  if (d.inSeconds < 10) return 'now';
  if (d.inSeconds < 60) return '${d.inSeconds} s ago';
  if (d.inMinutes < 60) return '${d.inMinutes} min ago';
  if (d.inHours < 24) return '${d.inHours} h ago';
  return '${d.inDays} d ago';
}
