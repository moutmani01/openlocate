import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:openlocate/location/disk_queue.dart';

void main() {
  late Directory dir;
  late File file;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('ol_queue_test');
    file = File('${dir.path}/pending.jsonl');
  });

  tearDown(() => dir.deleteSync(recursive: true));

  Map<String, dynamic> item(int n) => {'event_id': 'e$n', 'payload': 'p$n'};

  test('items survive a restart, in order', () async {
    final q = DiskQueue(file, maxItems: 100);
    await q.load();
    for (var i = 0; i < 5; i++) {
      await q.add(item(i));
    }

    final reopened = DiskQueue(file, maxItems: 100);
    await reopened.load();
    expect(reopened.length, 5);
    expect(reopened.peek(2).map((e) => e['event_id']), ['e0', 'e1']);
  });

  test('removing delivered items keeps the rest; an empty queue leaves no file', () async {
    final q = DiskQueue(file, maxItems: 100);
    await q.load();
    for (var i = 0; i < 5; i++) {
      await q.add(item(i));
    }
    await q.removeFirst(3);

    final reopened = DiskQueue(file, maxItems: 100);
    await reopened.load();
    expect(reopened.peek(10).map((e) => e['event_id']), ['e3', 'e4']);

    await reopened.removeFirst(10);
    expect(reopened.isEmpty, isTrue);
    expect(file.existsSync(), isFalse);
  });

  test('the oldest items are dropped beyond the limit', () async {
    final q = DiskQueue(file, maxItems: 3);
    await q.load();
    for (var i = 0; i < 5; i++) {
      await q.add(item(i));
    }
    expect(q.peek(10).map((e) => e['event_id']), ['e2', 'e3', 'e4']);

    final reopened = DiskQueue(file, maxItems: 3);
    await reopened.load();
    expect(reopened.peek(10).map((e) => e['event_id']), ['e2', 'e3', 'e4']);
  });

  test('a line cut short by a crash is skipped, the rest is kept', () async {
    file.writeAsStringSync('{"event_id":"e0","payload":"p0"}\n{"event_id":"e1","pay');
    final q = DiskQueue(file, maxItems: 100);
    await q.load();
    expect(q.peek(10).map((e) => e['event_id']), ['e0']);

    // The damaged tail must not swallow the next item that is appended.
    await q.add(item(2));
    final reopened = DiskQueue(file, maxItems: 100);
    await reopened.load();
    expect(reopened.peek(10).map((e) => e['event_id']), ['e0', 'e2']);
  });

  test('clear empties the queue and removes the file', () async {
    final q = DiskQueue(file, maxItems: 100);
    await q.load();
    await q.add(item(0));
    await q.clear();
    expect(q.length, 0);
    expect(file.existsSync(), isFalse);
  });
}
