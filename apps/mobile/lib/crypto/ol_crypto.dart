// Dart port of packages/crypto (TypeScript reference). Byte-for-byte compatible; checked against
// packages/crypto/test/vectors.json in test/crypto_test.dart.
import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as dc;
import 'package:sodium/sodium_sumo.dart';

String b64url(List<int> bytes) => base64Url.encode(bytes).replaceAll('=', '');

Uint8List unb64url(String s) => base64Url.decode(base64Url.normalize(s));

Uint8List utf8Bytes(String s) => Uint8List.fromList(utf8.encode(s));

Uint8List concat(List<List<int>> parts) {
  final b = BytesBuilder(copy: false);
  for (final p in parts) {
    b.add(p);
  }
  return b.toBytes();
}

Uint8List sha256(List<int> data) => Uint8List.fromList(dc.sha256.convert(data).bytes);

Uint8List hmacSha256(List<int> key, List<int> data) => Uint8List.fromList(dc.Hmac(dc.sha256, key).convert(data).bytes);

/// Public record a device publishes to a group (wire format, all base64url).
class MemberKeys {
  MemberKeys({required this.deviceId, required this.signPk, required this.boxPk, required this.boxSig});

  final String deviceId;
  final String signPk;
  final String boxPk;
  final String boxSig;

  factory MemberKeys.fromJson(Map<String, dynamic> j) => MemberKeys(
        deviceId: j['device_id'] as String,
        signPk: j['sign_pk'] as String,
        boxPk: j['box_pk'] as String,
        boxSig: j['box_sig'] as String,
      );

  Map<String, dynamic> toJson() => {'device_id': deviceId, 'sign_pk': signPk, 'box_pk': boxPk, 'box_sig': boxSig};
}

/// A device's long-term keys. Secret keys never leave the device.
class Identity {
  Identity._(this.deviceId, this.signPk, this.signSk, this.boxPk, this.boxSk);

  final String deviceId;
  final Uint8List signPk;
  final SecureKey signSk;
  final Uint8List boxPk;
  final SecureKey boxSk;
}

class LocationPoint {
  LocationPoint({required this.ts, required this.lat, required this.lon, this.acc, this.alt, this.spd, this.hdg, this.bat});

  /// Unix seconds of the fix.
  final int ts;
  final double lat;
  final double lon;
  final double? acc;
  final double? alt;
  final double? spd;
  final double? hdg;
  final double? bat;

  factory LocationPoint.fromJson(Map<String, dynamic> j) {
    double? d(String k) => (j[k] as num?)?.toDouble();
    return LocationPoint(
      ts: (j['ts'] as num).toInt(),
      lat: (j['lat'] as num).toDouble(),
      lon: (j['lon'] as num).toDouble(),
      acc: d('acc'),
      alt: d('alt'),
      spd: d('spd'),
      hdg: d('hdg'),
      bat: d('bat'),
    );
  }
}

class EventContext {
  EventContext({required this.groupId, required this.deviceId, required this.eventId, required this.epoch});

  final String groupId;
  final String deviceId;
  final String eventId;
  final int epoch;
}

/// Everything derived from one invitation secret (see docs/PROTOCOL.md).
class Invite {
  Invite._(this.secret, this.inviteId, this.authKey, this.authHash, this.macKey);

  final Uint8List secret;
  final String inviteId;
  final Uint8List authKey;
  final String authHash;
  final Uint8List macKey;
}

/// Contents of an invite QR code / link. Short-lived and single-use.
class InviteLink {
  InviteLink({required this.backend, required this.groupId, required this.secret, required this.inviter, required this.expiresAt, this.name});

  final String backend;
  final String groupId;
  final Uint8List secret;
  final String inviter;
  final int expiresAt;
  final String? name;

  String encode() {
    final q = {'b': backend, 'g': groupId, 's': b64url(secret), 'i': inviter, 'e': '$expiresAt', if (name != null && name!.isNotEmpty) 'n': name!};
    return 'openlocate://invite?${Uri(queryParameters: q).query}';
  }

  static InviteLink decode(String link) {
    final u = Uri.parse(link.trim());
    if (u.scheme != 'openlocate' || u.host != 'invite') throw const FormatException('Not an OpenLocate invite');
    String get(String k) {
      final v = u.queryParameters[k];
      if (v == null || v.isEmpty) throw FormatException("Invite is missing '$k'");
      return v;
    }

    final backend = Uri.parse(get('b'));
    final local = backend.host == 'localhost' || backend.host == '127.0.0.1';
    if (backend.scheme != 'https' && !local) throw const FormatException('Invite backend must use https');
    return InviteLink(
      backend: backend.origin,
      groupId: get('g'),
      secret: unb64url(get('s')),
      inviter: get('i'),
      expiresAt: int.parse(get('e')),
      name: u.queryParameters['n'],
    );
  }
}

class OlCrypto {
  OlCrypto(this.sodium);

  final SodiumSumo sodium;

  static const _padBlock = 64;
  static const _nonceBytes = 24;

  // ---------------------------------------------------------------- identity

  String deviceIdOf(Uint8List signPk) => b64url(sha256(signPk).sublist(0, 16));

  Identity createIdentity() {
    final sign = sodium.crypto.sign.keyPair();
    final box = sodium.crypto.box.keyPair();
    return Identity._(deviceIdOf(sign.publicKey), sign.publicKey, sign.secretKey, box.publicKey, box.secretKey);
  }

  Identity identityFromSeeds(Uint8List signSeed, Uint8List boxSeed) {
    final sign = sodium.crypto.sign.seedKeyPair(sodium.secureCopy(signSeed));
    final box = sodium.crypto.box.seedKeyPair(sodium.secureCopy(boxSeed));
    return Identity._(deviceIdOf(sign.publicKey), sign.publicKey, sign.secretKey, box.publicKey, box.secretKey);
  }

  /// Serialized for OS secure storage only.
  String exportIdentity(Identity id) =>
      jsonEncode({'v': 1, 'sign_sk': b64url(id.signSk.extractBytes()), 'box_sk': b64url(id.boxSk.extractBytes())});

  Identity importIdentity(String json) {
    final o = jsonDecode(json) as Map<String, dynamic>;
    if (o['v'] != 1) throw const FormatException('Unsupported identity version');
    final signSk = sodium.secureCopy(unb64url(o['sign_sk'] as String));
    final boxSk = sodium.secureCopy(unb64url(o['box_sk'] as String));
    final signPk = sodium.crypto.sign.skToPk(signSk);
    final boxPk = sodium.crypto.scalarmult.base(n: boxSk);
    return Identity._(deviceIdOf(signPk), signPk, signSk, boxPk, boxSk);
  }

  Uint8List _boxKeyMessage(Uint8List boxPk) => concat([utf8Bytes('OL1-BOXKEY\n'), boxPk]);

  MemberKeys memberKeys(Identity id) => MemberKeys(
        deviceId: id.deviceId,
        signPk: b64url(id.signPk),
        boxPk: b64url(id.boxPk),
        boxSig: b64url(sodium.crypto.sign.detached(message: _boxKeyMessage(id.boxPk), secretKey: id.signSk)),
      );

  bool verifyMemberKeys(MemberKeys m) {
    try {
      final signPk = unb64url(m.signPk);
      final boxPk = unb64url(m.boxPk);
      return signPk.length == 32 &&
          boxPk.length == 32 &&
          deviceIdOf(signPk) == m.deviceId &&
          sodium.crypto.sign.verifyDetached(message: _boxKeyMessage(boxPk), signature: unb64url(m.boxSig), publicKey: signPk);
    } catch (_) {
      return false;
    }
  }

  /// 12 groups of 5 digits to compare in person.
  String safetyNumber(Uint8List signPk) {
    final h = sha256(concat([utf8Bytes('OL1-SAFETY\n'), signPk]));
    final groups = <String>[];
    for (var i = 0; i < 12; i++) {
      final n = ((h[i * 2] << 16) | (h[i * 2 + 1] << 8) | h[24 + (i % 8)]) % 100000;
      groups.add(n.toString().padLeft(5, '0'));
    }
    return groups.join(' ');
  }

  // ---------------------------------------------------------------- request signing

  String requestPayload(String method, String target, int timestampMs, String nonce, String bodyHash) =>
      ['OL1-REQ', method.toUpperCase(), target, '$timestampMs', nonce, bodyHash].join('\n');

  Map<String, String> signRequest(Identity id, String method, String target, Uint8List body, {int? now, String? fixedNonce}) {
    final ts = now ?? DateTime.now().millisecondsSinceEpoch;
    final nonce = fixedNonce ?? b64url(sodium.randombytes.buf(16));
    final payload = requestPayload(method, target, ts, nonce, b64url(sha256(body)));
    final sig = sodium.crypto.sign.detached(message: utf8Bytes(payload), secretKey: id.signSk);
    return {
      'x-ol-device': b64url(id.signPk),
      'x-ol-timestamp': '$ts',
      'x-ol-nonce': nonce,
      'x-ol-signature': b64url(sig),
    };
  }

  /// Query parameters authenticating a WebSocket upgrade to [path].
  Map<String, String> signWebSocket(Identity id, String path) {
    final h = signRequest(id, 'GET', path, Uint8List(0));
    return {'device': h['x-ol-device']!, 'ts': h['x-ol-timestamp']!, 'nonce': h['x-ol-nonce']!, 'sig': h['x-ol-signature']!};
  }

  // ---------------------------------------------------------------- invitations

  Uint8List _kdf(Uint8List secret, int id, int len) {
    final master = sodium.secureCopy(secret);
    try {
      final sub = sodium.crypto.kdf.deriveFromKey(masterKey: master, context: 'OLinvite', subkeyId: BigInt.from(id), subkeyLen: len);
      final bytes = sub.extractBytes();
      sub.dispose();
      return bytes;
    } finally {
      master.dispose();
    }
  }

  Invite newInvite() => deriveInvite(sodium.randombytes.buf(32));

  Invite deriveInvite(Uint8List secret) {
    if (secret.length != 32) throw ArgumentError('invite secret must be 32 bytes');
    final authKey = _kdf(secret, 1, 32);
    return Invite._(secret, b64url(_kdf(secret, 3, 16)), authKey, b64url(sha256(authKey)), _kdf(secret, 2, 32));
  }

  Uint8List _bindingMessage(String groupId, MemberKeys m) => utf8Bytes(['OL1-JOIN', groupId, m.signPk, m.boxPk].join('\n'));

  String joinBinding(Invite inv, String groupId, MemberKeys m) => b64url(hmacSha256(inv.macKey, _bindingMessage(groupId, m)));

  bool verifyJoinBinding(Invite inv, String groupId, MemberKeys m, String binding) {
    try {
      return sodium.memcmp(hmacSha256(inv.macKey, _bindingMessage(groupId, m)), unb64url(binding));
    } catch (_) {
      return false;
    }
  }

  // ---------------------------------------------------------------- key cards

  Uint8List _cardSigned(String groupId, String to, Uint8List sealed) => concat([utf8Bytes('OL1-CARD\n$groupId\n$to\n'), sealed]);

  /// Returns the wire envelope {sealed, sig}.
  Map<String, String> sealCard(Identity sender, MemberKeys recipient, Map<String, dynamic> content) {
    if (content['from'] != sender.deviceId || content['to'] != recipient.deviceId) throw ArgumentError('card from/to mismatch');
    final sealed = sodium.crypto.box.seal(message: utf8Bytes(jsonEncode(content)), publicKey: unb64url(recipient.boxPk));
    final sig = sodium.crypto.sign.detached(message: _cardSigned(content['group_id'] as String, recipient.deviceId, sealed), secretKey: sender.signSk);
    return {'sealed': b64url(sealed), 'sig': b64url(sig)};
  }

  /// Verifies, decrypts and checks the header. Throws on any failure.
  Map<String, dynamic> openCard(Identity recipient, MemberKeys sender, String groupId, Map<String, dynamic> envelope) {
    final sealed = unb64url(envelope['sealed'] as String);
    final ok = sodium.crypto.sign.verifyDetached(
      message: _cardSigned(groupId, recipient.deviceId, sealed),
      signature: unb64url(envelope['sig'] as String),
      publicKey: unb64url(sender.signPk),
    );
    if (!ok) throw const FormatException('card signature invalid');
    final plain = sodium.crypto.box.sealOpen(cipherText: sealed, publicKey: recipient.boxPk, secretKey: recipient.boxSk);
    final c = jsonDecode(utf8.decode(plain)) as Map<String, dynamic>;
    if (c['v'] != 1 || c['group_id'] != groupId || c['from'] != sender.deviceId || c['to'] != recipient.deviceId) {
      throw const FormatException('card header mismatch');
    }
    return c;
  }

  // ---------------------------------------------------------------- location

  Uint8List newLocationKey() => sodium.randombytes.buf(32);

  String newEventId(String deviceId) => '$deviceId:${b64url(sodium.randombytes.buf(16))}';

  Uint8List _aad(EventContext c) => utf8Bytes(['OL1-LOC', c.groupId, c.deviceId, c.eventId, '${c.epoch}'].join('\n'));

  /// Same field order, rounding and number formatting as the TypeScript implementation.
  Map<String, Object> canonical(LocationPoint p) {
    num r(double v, int d) {
      final f = [1, 10, 100, 1000, 10000, 100000, 1000000][d];
      final x = (v * f).round() / f;
      return x == x.roundToDouble() ? x.toInt() : x;
    }

    return {
      'ts': p.ts,
      'lat': r(p.lat, 6),
      'lon': r(p.lon, 6),
      if (p.acc != null) 'acc': r(p.acc!, 1),
      if (p.alt != null) 'alt': r(p.alt!, 1),
      if (p.spd != null) 'spd': r(p.spd!, 1),
      if (p.hdg != null) 'hdg': p.hdg!.round(),
      if (p.bat != null) 'bat': p.bat!.round(),
    };
  }

  String encryptLocation(Uint8List key, EventContext ctx, LocationPoint point, {Uint8List? nonce}) {
    final n = nonce ?? sodium.randombytes.buf(_nonceBytes);
    final plain = sodium.pad(utf8Bytes(jsonEncode(canonical(point))), _padBlock);
    final k = sodium.secureCopy(key);
    try {
      final ct = sodium.crypto.aeadXChaCha20Poly1305IETF.encrypt(message: plain, nonce: n, key: k, additionalData: _aad(ctx));
      return b64url(concat([n, ct]));
    } finally {
      k.dispose();
    }
  }

  LocationPoint decryptLocation(Uint8List key, EventContext ctx, String payload) {
    final raw = unb64url(payload);
    if (raw.length < _nonceBytes + 16) throw const FormatException('payload too short');
    final k = sodium.secureCopy(key);
    try {
      final plain = sodium.crypto.aeadXChaCha20Poly1305IETF.decrypt(
        cipherText: raw.sublist(_nonceBytes),
        nonce: raw.sublist(0, _nonceBytes),
        key: k,
        additionalData: _aad(ctx),
      );
      return LocationPoint.fromJson(jsonDecode(utf8.decode(sodium.unpad(plain, _padBlock))) as Map<String, dynamic>);
    } finally {
      k.dispose();
    }
  }
}
