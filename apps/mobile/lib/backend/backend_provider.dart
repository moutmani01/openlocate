// Mirrors packages/client/src/provider.ts. The app talks only to this interface, so other
// backends can be plugged in. Everything crossing it is already end-to-end encrypted.
import '../crypto/ol_crypto.dart';

class BackendException implements Exception {
  BackendException(this.status, this.code);

  final int status;
  final String code;

  @override
  String toString() => 'BackendException($status, $code)';
}

class GroupMember {
  GroupMember({required this.keys, required this.role, required this.invitedBy, required this.binding, required this.joinedAt});

  final MemberKeys keys;
  final String role;
  final String? invitedBy;
  final String? binding;
  final int joinedAt;

  String get deviceId => keys.deviceId;

  factory GroupMember.fromJson(Map<String, dynamic> j) => GroupMember(
        keys: MemberKeys.fromJson(j),
        role: j['role'] as String,
        invitedBy: j['invited_by'] as String?,
        binding: j['binding'] as String?,
        joinedAt: (j['joined_at'] as num).toInt(),
      );
}

class GroupState {
  GroupState({required this.groupId, required this.members, required this.shares});

  final String groupId;
  final List<GroupMember> members;

  /// (from, to) pairs: who currently shares with whom.
  final List<(String, String)> shares;

  factory GroupState.fromJson(Map<String, dynamic> j) => GroupState(
        groupId: j['group_id'] as String,
        members: (j['members'] as List).map((m) => GroupMember.fromJson(m as Map<String, dynamic>)).toList(),
        shares: (j['shares'] as List).map((s) => ((s as Map)['from'] as String, s['to'] as String)).toList(),
      );
}

class CardRecord {
  CardRecord({required this.from, required this.envelope, required this.epoch, required this.sharesLocation});

  final String from;
  final Map<String, dynamic> envelope;
  final int epoch;
  final bool sharesLocation;

  factory CardRecord.fromJson(Map<String, dynamic> j) => CardRecord(
        from: j['from'] as String,
        envelope: (j['envelope'] as Map).cast<String, dynamic>(),
        epoch: (j['epoch'] as num).toInt(),
        sharesLocation: j['shares_location'] as bool,
      );
}

/// Encrypted event as the server sees it.
class WireEvent {
  WireEvent({required this.deviceId, required this.eventId, required this.epoch, required this.payload, this.seq, this.expiresAt, this.store = true});

  final String deviceId;
  final String eventId;
  final int epoch;
  final String payload;
  final int? seq;
  final int? expiresAt;
  final bool store;

  factory WireEvent.fromJson(Map<String, dynamic> j) => WireEvent(
        deviceId: j['device_id'] as String,
        eventId: j['event_id'] as String,
        epoch: (j['epoch'] as num).toInt(),
        payload: j['payload'] as String,
        seq: (j['seq'] as num?)?.toInt(),
        expiresAt: (j['expires_at'] as num?)?.toInt(),
      );

  Map<String, dynamic> toPublishJson() => {'event_id': eventId, 'epoch': epoch, 'payload': payload, 'expires_at': expiresAt, 'store': store};
}

class HistoryPage {
  HistoryPage(this.events, this.nextAfter, this.more);

  final List<WireEvent> events;
  final int nextAfter;
  final bool more;
}

abstract interface class LiveConnection {
  void send(Map<String, dynamic> message);
  Future<void> close();
}

abstract interface class BackendProvider {
  Future<GroupState> createGroup(String groupId);
  Future<GroupState> getGroup(String groupId);
  Future<void> createInvitation(String groupId, {required String inviteId, required String authHash, required int expiresAt});
  Future<GroupState> joinGroup(String groupId, {required String inviteId, required String authKey, required MemberKeys member, required String binding});
  Future<void> removeMember(String groupId, String deviceId);
  Future<void> putCard(String groupId, String to, {required Map<String, String> envelope, required int epoch, required bool sharesLocation});
  Future<List<CardRecord>> getCards(String groupId);
  Future<Map<String, dynamic>> publish(String groupId, List<WireEvent> events);
  Future<HistoryPage> getHistory(String groupId, {int after = 0, String? from, int? limit});
  Future<void> deleteHistory(String groupId);

  /// Opens the group's live socket. [onMessage] gets decoded server messages; [onClosed] fires once.
  Future<LiveConnection> connect(String groupId, {required void Function(Map<String, dynamic>) onMessage, required void Function() onClosed});
}
