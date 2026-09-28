import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:web_socket_channel/io.dart';

import '../crypto/ol_crypto.dart';
import 'backend_provider.dart';

/// Speaks the OpenLocate v1 HTTP + WebSocket protocol (docs/PROTOCOL.md).
class HttpProvider implements BackendProvider {
  HttpProvider(String baseUrl, this.crypto, this.identity, {http.Client? client})
      : base = baseUrl.replaceAll(RegExp(r'/+$'), ''),
        _client = client ?? http.Client();

  final String base;
  final OlCrypto crypto;
  final Identity identity;
  final http.Client _client;

  String _g(String groupId, [String rest = '']) => '/v1/groups/$groupId$rest';

  Future<dynamic> _call(String method, String target, [Object? body]) async {
    final bytes = body == null ? Uint8List(0) : utf8Bytes(jsonEncode(body));
    final headers = crypto.signRequest(identity, method, target, bytes);
    if (body != null) headers['content-type'] = 'application/json';
    final req = http.Request(method, Uri.parse(base + target))
      ..headers.addAll(headers)
      ..bodyBytes = bytes;
    final res = await http.Response.fromStream(await _client.send(req).timeout(const Duration(seconds: 20)));
    if (res.statusCode >= 400) {
      String code = 'unknown';
      try {
        code = (jsonDecode(res.body) as Map)['error'] as String? ?? code;
      } catch (_) {}
      throw BackendException(res.statusCode, code);
    }
    return res.statusCode == 204 || res.body.isEmpty ? null : jsonDecode(res.body);
  }

  @override
  Future<GroupState> createGroup(String groupId) async =>
      GroupState.fromJson(await _call('PUT', _g(groupId), {'member': crypto.memberKeys(identity).toJson()}) as Map<String, dynamic>);

  @override
  Future<GroupState> getGroup(String groupId) async => GroupState.fromJson(await _call('GET', _g(groupId)) as Map<String, dynamic>);

  @override
  Future<void> createInvitation(String groupId, {required String inviteId, required String authHash, required int expiresAt}) =>
      _call('POST', _g(groupId, '/invitations'), {'invite_id': inviteId, 'auth_hash': authHash, 'expires_at': expiresAt});

  @override
  Future<GroupState> joinGroup(String groupId,
          {required String inviteId, required String authKey, required MemberKeys member, required String binding}) async =>
      GroupState.fromJson(await _call('POST', _g(groupId, '/join'),
          {'invite_id': inviteId, 'auth_key': authKey, 'member': member.toJson(), 'binding': binding}) as Map<String, dynamic>);

  @override
  Future<void> removeMember(String groupId, String deviceId) => _call('DELETE', _g(groupId, '/members/$deviceId'));

  @override
  Future<void> putCard(String groupId, String to, {required Map<String, String> envelope, required int epoch, required bool sharesLocation}) =>
      _call('PUT', _g(groupId, '/cards/$to'), {'envelope': envelope, 'epoch': epoch, 'shares_location': sharesLocation});

  @override
  Future<List<CardRecord>> getCards(String groupId) async {
    final r = await _call('GET', _g(groupId, '/cards')) as Map<String, dynamic>;
    return (r['cards'] as List).map((c) => CardRecord.fromJson(c as Map<String, dynamic>)).toList();
  }

  @override
  Future<Map<String, dynamic>> publish(String groupId, List<WireEvent> events) async =>
      await _call('POST', _g(groupId, '/events'), {'events': events.map((e) => e.toPublishJson()).toList()}) as Map<String, dynamic>;

  @override
  Future<HistoryPage> getHistory(String groupId, {int after = 0, String? from, int? limit}) async {
    final q = <String, String>{'after': '$after', 'from': ?from, if (limit != null) 'limit': '$limit'};
    final r = await _call('GET', _g(groupId, '/events?${Uri(queryParameters: q).query}')) as Map<String, dynamic>;
    return HistoryPage(
      (r['events'] as List).map((e) => WireEvent.fromJson(e as Map<String, dynamic>)).toList(),
      (r['next_after'] as num).toInt(),
      r['more'] as bool,
    );
  }

  @override
  Future<void> deleteHistory(String groupId) => _call('DELETE', _g(groupId, '/events'));

  @override
  Future<LiveConnection> connect(String groupId,
      {required void Function(Map<String, dynamic>) onMessage, required void Function() onClosed}) async {
    final path = _g(groupId, '/ws');
    final wsBase = base.replaceFirst(RegExp('^http'), 'ws');
    final uri = Uri.parse(wsBase + path).replace(queryParameters: crypto.signWebSocket(identity, path));
    final channel = IOWebSocketChannel.connect(uri, pingInterval: const Duration(seconds: 50));
    await channel.ready.timeout(const Duration(seconds: 20));
    var closed = false;
    void done() {
      if (!closed) {
        closed = true;
        onClosed();
      }
    }

    channel.stream.listen(
      (data) {
        try {
          onMessage(jsonDecode(data as String) as Map<String, dynamic>);
        } catch (_) {
          // The server is not trusted to send well-formed frames.
        }
      },
      onDone: done,
      onError: (_) => done(),
      cancelOnError: true,
    );
    return _Live(channel);
  }
}

class _Live implements LiveConnection {
  _Live(this.channel);

  final IOWebSocketChannel channel;

  @override
  void send(Map<String, dynamic> message) => channel.sink.add(jsonEncode(message));

  @override
  Future<void> close() async => channel.sink.close(1000);
}
