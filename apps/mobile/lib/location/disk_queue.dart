import 'dart:convert';
import 'dart:io';

/// A small first-in-first-out queue of JSON objects kept in one file, one object per line.
///
/// It holds location events that are already end-to-end encrypted, so that fixes taken while
/// offline survive the app or the phone being restarted. Appending is a single short write;
/// the file is rewritten only when items are removed, and deleted when the queue is empty.
class DiskQueue {
  DiskQueue(this.file, {required this.maxItems});

  final File file;

  /// Oldest items are dropped once the queue holds more than this.
  final int maxItems;

  final List<Map<String, dynamic>> _items = [];

  int get length => _items.length;
  bool get isEmpty => _items.isEmpty;

  /// Reads the file. Lines that are not valid JSON objects (a write cut short by a crash) are
  /// skipped, and the file is then rewritten so the next append starts on a clean line.
  Future<void> load() async {
    _items.clear();
    if (!await file.exists()) return;
    var damaged = false;
    for (final line in await file.readAsLines()) {
      if (line.isEmpty) continue;
      try {
        final item = jsonDecode(line);
        if (item is Map<String, dynamic>) {
          _items.add(item);
        } else {
          damaged = true;
        }
      } catch (_) {
        damaged = true;
      }
    }
    if (_items.length > maxItems) {
      _items.removeRange(0, _items.length - maxItems);
      damaged = true;
    }
    if (damaged) await _rewrite();
  }

  Future<void> add(Map<String, dynamic> item) async {
    _items.add(item);
    if (_items.length > maxItems) {
      _items.removeRange(0, _items.length - maxItems);
      await _rewrite();
    } else {
      await file.writeAsString('${jsonEncode(item)}\n', mode: FileMode.append, flush: true);
    }
  }

  /// The oldest [count] items, without removing them.
  List<Map<String, dynamic>> peek(int count) => _items.take(count).toList();

  Future<void> removeFirst(int count) async {
    if (count <= 0) return;
    _items.removeRange(0, count > _items.length ? _items.length : count);
    await _rewrite();
  }

  Future<void> clear() async {
    _items.clear();
    await _rewrite();
  }

  Future<void> _rewrite() async {
    if (_items.isEmpty) {
      if (await file.exists()) await file.delete();
      return;
    }
    // Write beside the file and rename, so a crash never leaves a half-written queue.
    final tmp = File('${file.path}.tmp');
    await tmp.writeAsString(_items.map((i) => '${jsonEncode(i)}\n').join(), flush: true);
    await tmp.rename(file.path);
  }
}
