import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import '../config.dart';
import '../location/tracker.dart';
import '../main.dart';
import '../state/app_state.dart';
import 'invite_screen.dart';
import 'member_screen.dart';
import 'settings_screen.dart';
import 'widgets.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final _map = MapController();
  Timer? _clock;
  bool _centered = false;

  @override
  void initState() {
    super.initState();
    // Refresh "x min ago" labels.
    _clock = Timer.periodic(const Duration(seconds: 15), (_) {
      if (mounted) setState(() {});
    });
    Tracker.currentPosition().then((p) {
      if (p != null && mounted && !_centered) {
        _centered = true;
        _map.move(LatLng(p.latitude, p.longitude), 14);
      }
    });
  }

  @override
  void dispose() {
    _clock?.cancel();
    super.dispose();
  }

  void _focus(LatLng p) => _map.move(p, 15);

  @override
  Widget build(BuildContext context) {
    final s = AppScope.of(context);
    final markers = <Marker>[];
    for (final id in [s.myId, ...s.others.map((m) => m.deviceId)]) {
      final f = s.latestOf(id);
      if (f == null) continue;
      markers.add(Marker(
        point: LatLng(f.point.lat, f.point.lon),
        width: 44,
        height: 44,
        child: Avatar(name: s.nameOf(id), id: id, size: 40, online: s.online.contains(id)),
      ));
    }

    return Scaffold(
      appBar: AppBar(
        title: Text(s.groupName ?? 'OpenLocate'),
        actions: [
          IconButton(
            tooltip: 'Invite',
            icon: const Icon(Icons.person_add_alt_1),
            onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const InviteScreen())),
          ),
          IconButton(
            tooltip: 'Settings',
            icon: const Icon(Icons.settings_outlined),
            onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const SettingsScreen())),
          ),
        ],
      ),
      body: Column(
        children: [
          if (s.error != null || !s.connected)
            MaterialBanner(
              content: Text(s.error ?? 'Connecting…'),
              leading: Icon(s.connected ? Icons.error_outline : Icons.cloud_off),
              actions: [TextButton(onPressed: () => s.refresh().catchError((_) {}), child: const Text('Retry'))],
            ),
          Expanded(
            flex: 5,
            child: FlutterMap(
              mapController: _map,
              options: const MapOptions(initialCenter: LatLng(33.5731, -7.5898), initialZoom: 11),
              children: [
                TileLayer(urlTemplate: AppConfig.tileUrl, userAgentPackageName: 'org.openlocate.openlocate'),
                MarkerLayer(markers: markers),
                const SimpleAttributionWidget(source: Text('OpenStreetMap contributors')),
              ],
            ),
          ),
          Expanded(
            flex: 4,
            child: RefreshIndicator(
              onRefresh: () => s.refresh().catchError((_) {}),
              child: ListView(
                padding: const EdgeInsets.only(bottom: 24),
                children: [
                  _SharingCard(state: s),
                  if (s.others.isEmpty)
                    const Padding(
                      padding: EdgeInsets.all(24),
                      child: Text('No one else here yet. Tap the invite button to add someone.', textAlign: TextAlign.center),
                    ),
                  for (final m in s.others) _MemberTile(state: s, deviceId: m.deviceId, onFocus: _focus),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _SharingCard extends StatelessWidget {
  const _SharingCard({required this.state});

  final AppState state;

  @override
  Widget build(BuildContext context) {
    final s = state;
    final theme = Theme.of(context);
    final n = s.shareWith.length;
    final actual = s.actualInterval;
    final retention = s.retentionHours == 0 ? 'not stored' : 'kept ${s.retentionHours < 48 ? '${s.retentionHours} h' : '${s.retentionHours ~/ 24} days'}';
    return Card(
      margin: const EdgeInsets.fromLTRB(12, 12, 12, 4),
      color: s.sharingActive ? theme.colorScheme.primaryContainer : null,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 8, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(s.sharingActive ? Icons.share_location : Icons.location_disabled),
                const SizedBox(width: 12),
                Expanded(child: Text(s.sharingActive ? 'Sharing my location' : 'Location sharing is off', style: theme.textTheme.titleMedium)),
                Switch(value: s.sharingActive, onChanged: (v) => s.setSharingActive(v)),
              ],
            ),
            Text(
              n == 0
                  ? 'Nobody can see you. Turn on “Can see me” for a person below.'
                  : 'Visible to $n ${n == 1 ? 'person' : 'people'} · requested every ${formatInterval(s.intervalSeconds)}'
                      '${actual != null ? ' · actual ~${formatInterval(actual.round())}' : ''} · history $retention',
              style: theme.textTheme.bodySmall,
            ),
            if (s.queued > 0) Text('${s.queued} update(s) waiting for a connection', style: theme.textTheme.bodySmall),
          ],
        ),
      ),
    );
  }
}

class _MemberTile extends StatelessWidget {
  const _MemberTile({required this.state, required this.deviceId, required this.onFocus});

  final AppState state;
  final String deviceId;
  final void Function(LatLng) onFocus;

  @override
  Widget build(BuildContext context) {
    final s = state;
    final peer = s.peers[deviceId];
    final fix = s.latestOf(deviceId);
    final online = s.online.contains(deviceId);
    final String subtitle;
    if (peer?.sharesWithMe != true) {
      subtitle = online ? 'Online · not sharing with you' : 'Not sharing with you';
    } else if (fix == null) {
      subtitle = online ? 'Online · no location yet' : 'No location yet';
    } else {
      subtitle = '${online ? 'Online' : 'Offline'} · ${formatAgo(fix.time)}${fix.point.acc != null ? ' · ±${fix.point.acc!.round()} m' : ''}';
    }
    return ListTile(
      leading: Avatar(name: s.nameOf(deviceId), id: deviceId, online: online),
      title: Row(
        children: [
          Flexible(child: Text(s.nameOf(deviceId), overflow: TextOverflow.ellipsis)),
          if (s.unverified.contains(deviceId))
            const Padding(
              padding: EdgeInsets.only(left: 6),
              child: Tooltip(message: 'Keys could not be verified — compare safety numbers', child: Icon(Icons.warning_amber, size: 18, color: Colors.orange)),
            ),
        ],
      ),
      subtitle: Text(subtitle),
      trailing: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            height: 28,
            child: Switch(
              value: s.shareWith.contains(deviceId),
              onChanged: (v) => s.setShareWith(deviceId, v),
            ),
          ),
          Text('Can see me', style: Theme.of(context).textTheme.labelSmall),
        ],
      ),
      onTap: () {
        if (fix != null) onFocus(LatLng(fix.point.lat, fix.point.lon));
        Navigator.of(context).push(MaterialPageRoute(builder: (_) => MemberScreen(deviceId: deviceId)));
      },
    );
  }
}
