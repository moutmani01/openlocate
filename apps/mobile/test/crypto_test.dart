import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:openlocate/crypto/ol_crypto.dart';
import 'package:sodium/sodium_sumo.dart';

/// Checks the Dart port against the TypeScript reference (packages/crypto/test/vectors.json).
void main() {
  late OlCrypto c;
  late Map<String, dynamic> v;

  setUpAll(() async {
    c = OlCrypto(await SodiumSumoInit.init());
    v = jsonDecode(File('../../packages/crypto/test/vectors.json').readAsStringSync()) as Map<String, dynamic>;
  });

  Identity id(String who) => c.identityFromSeeds(unb64url(v[who]['sign_seed'] as String), unb64url(v[who]['box_seed'] as String));

  test('identity: device id, member keys and safety number match', () {
    final alice = id('alice');
    expect(c.memberKeys(alice).toJson(), v['alice']['keys']);
    expect(c.safetyNumber(alice.signPk), v['alice']['safety_number']);
    expect(c.memberKeys(id('bob')).toJson(), v['bob']['keys']);
    expect(c.verifyMemberKeys(MemberKeys.fromJson(v['bob']['keys'] as Map<String, dynamic>)), isTrue);
  });

  test('identity survives secure-storage export/import', () {
    final a = c.createIdentity();
    final b = c.importIdentity(c.exportIdentity(a));
    expect(b.deviceId, a.deviceId);
    expect(b.boxPk, a.boxPk);
  });

  test('request signing matches byte-for-byte', () {
    final r = v['request'] as Map<String, dynamic>;
    final body = utf8Bytes(r['body'] as String);
    expect(b64url(sha256(body)), r['body_sha256']);
    expect(c.requestPayload(r['method'] as String, r['target'] as String, r['timestamp'] as int, r['nonce'] as String, r['body_sha256'] as String), r['payload']);
    final h = c.signRequest(id('alice'), r['method'] as String, r['target'] as String, body, now: r['timestamp'] as int, fixedNonce: r['nonce'] as String);
    expect(h['x-ol-signature'], r['signature']);
  });

  test('invitation derivation and join binding match', () {
    final i = v['invite'] as Map<String, dynamic>;
    final inv = c.deriveInvite(unb64url(i['secret'] as String));
    expect(inv.inviteId, i['invite_id']);
    expect(b64url(inv.authKey), i['auth_key']);
    expect(inv.authHash, i['auth_hash']);
    expect(b64url(inv.macKey), i['mac_key']);
    final bob = c.memberKeys(id('bob'));
    expect(c.joinBinding(inv, v['group_id'] as String, bob), i['bob_binding']);
    expect(c.verifyJoinBinding(inv, v['group_id'] as String, bob, i['bob_binding'] as String), isTrue);
    expect(c.verifyJoinBinding(inv, v['group_id'] as String, c.memberKeys(id('alice')), i['bob_binding'] as String), isFalse);
  });

  test('opens a key card sealed by the TypeScript implementation', () {
    final card = c.openCard(id('bob'), MemberKeys.fromJson(v['alice']['keys'] as Map<String, dynamic>), v['group_id'] as String,
        (v['card']['envelope'] as Map).cast<String, dynamic>());
    expect(card['display_name'], 'Alice ☀');
    expect(card['location_key'], v['location']['key']);
  });

  test('card round trip and rejection of the wrong recipient', () {
    final a = c.createIdentity();
    final b = c.createIdentity();
    final env = c.sealCard(a, c.memberKeys(b), {'v': 1, 'group_id': 'g', 'from': a.deviceId, 'to': b.deviceId, 'epoch': 1, 'issued_at': 1, 'display_name': 'A'});
    expect(c.openCard(b, c.memberKeys(a), 'g', env)['display_name'], 'A');
    expect(() => c.openCard(c.createIdentity(), c.memberKeys(a), 'g', env), throwsA(anything));
  });

  test('location encryption matches byte-for-byte and decrypts', () {
    final l = v['location'] as Map<String, dynamic>;
    final ctx = EventContext(groupId: l['group_id'] as String, deviceId: l['device_id'] as String, eventId: l['event_id'] as String, epoch: l['epoch'] as int);
    final key = unb64url(l['key'] as String);
    final point = LocationPoint.fromJson((l['point'] as Map).cast<String, dynamic>());
    expect(c.encryptLocation(key, ctx, point, nonce: unb64url(l['nonce'] as String)), l['payload']);
    final back = c.decryptLocation(key, ctx, l['payload'] as String);
    expect(back.lat, point.lat);
    expect(back.acc, 12);
    expect(() => c.decryptLocation(c.newLocationKey(), ctx, l['payload'] as String), throwsA(anything));
  });

  test('invite links round trip and refuse plain http', () {
    final link = InviteLink(backend: 'https://ol.example.org', groupId: 'g', secret: c.newInvite().secret, inviter: 'i', expiresAt: 5, name: 'Family & co');
    final back = InviteLink.decode(link.encode());
    expect(back.name, 'Family & co');
    expect(back.backend, 'https://ol.example.org');
    expect(() => InviteLink.decode(link.encode().replaceFirst('https%3A', 'http%3A')), throwsFormatException);
  });
}
