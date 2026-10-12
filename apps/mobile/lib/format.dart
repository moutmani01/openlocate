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

/// Text of the ongoing notification while sharing.
String sharingNotificationText(int people, int intervalSeconds) =>
    'Visible to $people ${people == 1 ? 'person' : 'people'} · every ${formatInterval(intervalSeconds)}';
