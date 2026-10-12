import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';

import '../config.dart';
import '../location/tracker.dart';
import '../main.dart';
import '../state/app_state.dart';
import 'widgets.dart';

const _intervals = [15, 30, 60, 300, 600, 900, 1800, 3600];
const _retentions = {0: 'Never store (live only)', 1: '1 hour', 6: '6 hours', 24: '24 hours', 72: '3 days', 168: '7 days', 720: '30 days', 2160: '90 days'};

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  Future<void> _customInterval(BuildContext context, AppState s) async {
    final c = TextEditingController(text: '${s.intervalSeconds}');
    final v = await showDialog<int>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Custom interval'),
        content: TextField(controller: c, keyboardType: TextInputType.number, decoration: const InputDecoration(suffixText: 'seconds')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, int.tryParse(c.text)), child: const Text('Set')),
        ],
      ),
    );
    if (v != null && v >= 5) await s.setInterval(v);
  }

  Future<void> _rename(BuildContext context, AppState s) async {
    final c = TextEditingController(text: s.displayName);
    final v = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Your name'),
        content: TextField(controller: c, autofocus: true, textCapitalization: TextCapitalization.words),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, c.text), child: const Text('Save')),
        ],
      ),
    );
    if (v != null && v.trim().isNotEmpty) await s.setDisplayName(v);
  }

  @override
  Widget build(BuildContext context) {
    final s = AppScope.of(context);
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        children: [
          ListTile(leading: const Icon(Icons.badge_outlined), title: const Text('Your name'), subtitle: Text(s.displayName), onTap: () => _rename(context, s)),
          const Divider(),
          _Header('Updates'),
          ListTile(
            leading: const Icon(Icons.timer_outlined),
            title: const Text('Desired update interval'),
            subtitle: Text(
              'Every ${formatInterval(s.intervalSeconds)}. The phone may update less often to save battery or when you are not moving.',
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Wrap(
              spacing: 8,
              runSpacing: 4,
              children: [
                for (final i in _intervals)
                  ChoiceChip(label: Text(formatInterval(i)), selected: s.intervalSeconds == i, onSelected: (_) => s.setInterval(i)),
                ChoiceChip(
                  label: const Text('Custom…'),
                  selected: !_intervals.contains(s.intervalSeconds),
                  onSelected: (_) => _customInterval(context, s),
                ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          RadioGroup<BatteryMode>(
            groupValue: s.mode,
            onChanged: (v) {
              if (v != null) s.setMode(v);
            },
            child: Column(
              children: [
                for (final m in BatteryMode.values) RadioListTile<BatteryMode>(value: m, title: Text(m.label), subtitle: Text(m.description)),
              ],
            ),
          ),
          const Divider(),
          _Header('Background reliability'),
          _Reliability(state: s),
          const Divider(),
          _Header('History'),
          RadioGroup<int>(
            groupValue: s.retentionHours,
            onChanged: (v) {
              if (v != null) s.setRetention(v);
            },
            child: Column(
              children: [
                for (final e in _retentions.entries) RadioListTile<int>(value: e.key, title: Text(e.value), dense: true),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Text('Applies to new updates. The server deletes each point automatically when it expires.', style: theme.textTheme.bodySmall),
          ),
          ListTile(
            leading: const Icon(Icons.delete_sweep_outlined),
            title: const Text('Delete my stored history now'),
            onTap: () async {
              try {
                await s.deleteMyHistory();
                if (context.mounted) showError(context, 'Your stored history was deleted.');
              } catch (e) {
                if (context.mounted) showError(context, describeError(e));
              }
            },
          ),
          const Divider(),
          _Header('This device'),
          ListTile(
            leading: const Icon(Icons.fingerprint),
            title: const Text('Your safety number'),
            subtitle: SelectableText(s.safetyNumber, style: const TextStyle(fontFamily: 'monospace')),
          ),
          ListTile(leading: const Icon(Icons.dns_outlined), title: const Text('Server'), subtitle: Text(s.backendUrl)),
          ListTile(leading: const Icon(Icons.info_outline), title: const Text('Version'), subtitle: Text(AppConfig.appVersion)),
          const Divider(),
          ListTile(
            leading: Icon(Icons.logout, color: theme.colorScheme.error),
            title: Text('Leave group', style: TextStyle(color: theme.colorScheme.error)),
            subtitle: const Text('Stops sharing and deletes your data from the group.'),
            onTap: () async {
              final ok = await showDialog<bool>(
                context: context,
                builder: (c) => AlertDialog(
                  title: const Text('Leave this group?'),
                  content: const Text('Your location history on the server is deleted. You will need a new invitation to come back.'),
                  actions: [
                    TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
                    FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Leave')),
                  ],
                ),
              );
              if (ok != true) return;
              await s.leaveGroup();
              if (context.mounted) Navigator.of(context).popUntil((r) => r.isFirst);
            },
          ),
          const SizedBox(height: 24),
        ],
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
        child: Text(text, style: Theme.of(context).textTheme.titleSmall?.copyWith(color: Theme.of(context).colorScheme.primary)),
      );
}

/// Shows whether Android will let sharing keep running, and offers the fixes.
class _Reliability extends StatefulWidget {
  const _Reliability({required this.state});

  final AppState state;

  @override
  State<_Reliability> createState() => _ReliabilityState();
}

class _ReliabilityState extends State<_Reliability> with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    widget.state.refreshReliability();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  // The answers change in the system settings, so read them again on the way back.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) widget.state.refreshReliability();
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.state;
    final always = s.locationPermission == LocationPermission.always;
    return Column(
      children: [
        ListTile(
          leading: Icon(s.batteryExempt ? Icons.battery_full : Icons.battery_alert),
          title: const Text('Battery optimisation'),
          subtitle: Text(
            s.batteryExempt
                ? 'Not restricted. Sharing can keep running with the screen off.'
                : 'Restricted. Android may stop sharing without warning. Tap to allow.',
          ),
          onTap: s.batteryExempt ? null : s.requestBatteryExemption,
        ),
        ListTile(
          leading: Icon(always ? Icons.my_location : Icons.location_searching),
          title: const Text('Location access'),
          subtitle: Text(
            always
                ? 'Allowed all the time. Sharing can restart by itself.'
                : 'Only while in use. If Android stops sharing, it stays off until you open the app. '
                    'Tap and choose “Allow all the time” to let it restart by itself.',
          ),
          onTap: always ? null : s.requestBackgroundLocation,
        ),
        SwitchListTile(
          secondary: const Icon(Icons.restart_alt),
          title: const Text('Resume sharing after a restart'),
          subtitle: Text(always ? 'Start sharing again when the phone is switched on.' : 'Needs location access all the time.'),
          value: s.restartOnBoot && always,
          onChanged: always ? s.setRestartOnBoot : null,
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
          child: Text(
            'Some phones (Xiaomi, Huawei, Samsung, OnePlus) close background apps on their own. '
            'If sharing still stops, look up your model on dontkillmyapp.com.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ),
      ],
    );
  }
}
