import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:openlocate/backend/http_provider.dart';

void main() {
  MockClient answering(int status, String body) => MockClient((req) async {
        expect(req.url.path, '/v1/info');
        return http.Response(body, status);
      });

  test('accepts a relay that reports protocol 1', () async {
    expect(await HttpProvider.checkRelay('https://relay.example/', client: answering(200, '{"protocol_version":1}')), isNull);
  });

  test('requires https', () async {
    expect(await HttpProvider.checkRelay('http://relay.example', client: answering(200, '{"protocol_version":1}')), contains('https://'));
    expect(await HttpProvider.checkRelay('relay.example', client: answering(200, '{}')), isNotNull);
  });

  test('rejects something that is not a relay', () async {
    expect(await HttpProvider.checkRelay('https://example.com', client: answering(404, 'Not found')), contains('No OpenLocate relay'));
    expect(await HttpProvider.checkRelay('https://example.com', client: answering(200, '<html>')), contains('No OpenLocate relay'));
    expect(await HttpProvider.checkRelay('https://example.com', client: answering(200, '{"protocol_version":2}')), contains('version'));
  });
}
