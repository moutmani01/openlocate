import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import '../config.dart';
import '../crypto/ol_crypto.dart';
import '../main.dart';
import '../state/app_state.dart';
import 'widgets.dart';

enum _Range {
  hour('1 h', Duration(hours: 1)),
  today('Today', null),
  day('24 h', Duration(hours: 24)),
  week('7 days', Duration(days: 7));

  const _Range(this.label, this.duration);

  final String label;
  final Duration? duration;
}

/// One member: current location, details, and their movement history as a path.
class MemberScreen extends StatefulWidget {
  const MemberScreen({super.key, required this.deviceId});

  final String deviceId;

  @override
  State<MemberScreen> createState() => _MemberScreenState();
}

class _MemberScreenState extends State<MemberScreen> {
  _Range _range = _Range.today;

  @override
  Widget build(BuildContext context) {
    final s = AppScope.of(context);
    final id = widget.deviceId;
    final now = DateTime.now();
    final from = _range.duration == null ? DateTime(now.year, now.month, now.day) : now.subtract(_range.duration!);
    final fixes = (s.history[id] ?? const <Fix>[]).where((f) => f.time.isAfter(from)).toList();
    final points = fixes.map((f) => LatLng(f.point.lat, f.point.lon)).toList();
    final latest = s.latestOf(id);
    final member = s.group?.members.where((m) => m.deviceId == id).firstOrNull;
    final isAdmin = s.group?.members.any((m) => m.deviceId == s.myId && m.role == 'admin') ?? false;
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(title: Text(s.nameOf(id))),
      body: Column(
        children: [
          Expanded(
            child: FlutterMap(
              key: ValueKey('${_range.name}-${points.length}'),
              options: MapOptions(
                initialCenter: latest != null ? LatLng(latest.point.lat, latest.point.lon) : const LatLng(33.5731, -7.5898),
                initialZoom: 14,
                initialCameraFit: points.length > 1 ? CameraFit.coordinates(coordinates: points, padding: const EdgeInsets.all(40)) : null,
              ),
              children: [
                TileLayer(urlTemplate: AppConfig.tileUrl, userAgentPackageName: 'org.openlocate.openlocate'),
                if (points.length > 1)
                  PolylineLayer(polylines: [Polyline(points: points, strokeWidth: 4, color: Avatar.colorFor(id))]),
                MarkerLayer(markers: [
                  for (final p in points.length > 1 ? points.sublist(0, points.length - 1) : const <LatLng>[])
                    Marker(point: p, width: 8, height: 8, child: DecoratedBox(decoration: BoxDecoration(color: Avatar.colorFor(id), shape: BoxShape.circle))),
                  if (latest != null)
                    Marker(
                      point: LatLng(latest.point.lat, latest.point.lon),
                      width: 44,
                      height: 44,
                      child: Avatar(name: s.nameOf(id), id: id, online: s.online.contains(id)),
                    ),
                ]),
                const SimpleAttributionWidget(source: Text('OpenStreetMap contributors')),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
            child: Wrap(
              spacing: 8,
              children: [
                for (final r in _Range.values)
                  ChoiceChip(label: Text(r.label), selected: r == _range, onSelected: (_) => setState(() => _range = r)),
              ],
            ),
          ),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.all(16),
              children: [
                if (latest == null)
                  Text(s.peers[id]?.sharesWithMe == true ? 'No location received yet.' : '${s.nameOf(id)} is not sharing their location with you.')
                else ...[
                  Text('Updated ${formatAgo(latest.time)}', style: theme.textTheme.titleMedium),
                  if (latest.point.acc != null) Text('Accuracy ±${latest.point.acc!.round()} m'),
                  if (latest.point.spd != null) Text('Speed ${(latest.point.spd! * 3.6).round()} km/h'),
                  if (latest.point.bat != null) Text('Battery ${latest.point.bat!.round()}%'),
                  Text('${fixes.length} points in this period'),
                ],
                const Divider(height: 32),
                Text('Safety number', style: theme.textTheme.titleSmall),
                const SizedBox(height: 4),
                if (member != null) SelectableText(s.crypto.safetyNumber(unb64url(member.keys.signPk)), style: const TextStyle(fontFamily: 'monospace')),
                Text('Compare with the number in their Settings, in person, to be sure you are sharing with the right phone.', style: theme.textTheme.bodySmall),
                if (isAdmin) ...[
                  const SizedBox(height: 24),
                  OutlinedButton.icon(
                    icon: const Icon(Icons.person_remove_outlined),
                    label: const Text('Remove from group'),
                    onPressed: () async {
                      final ok = await showDialog<bool>(
                        context: context,
                        builder: (c) => AlertDialog(
                          title: Text('Remove ${s.nameOf(id)}?'),
                          content: const Text('They lose access immediately, and everyone who shared with them switches to a new key.'),
                          actions: [
                            TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
                            FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Remove')),
                          ],
                        ),
                      );
                      if (ok != true || !context.mounted) return;
                      try {
                        await s.removeMember(id);
                        if (context.mounted) Navigator.of(context).pop();
                      } catch (e) {
                        if (context.mounted) showError(context, describeError(e));
                      }
                    },
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}
