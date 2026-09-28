import 'package:flutter/material.dart';

import '../main.dart';
import 'scan_screen.dart';
import 'widgets.dart';

/// First run: pick a name, then create a group or join one with an invitation.
class WelcomeScreen extends StatefulWidget {
  const WelcomeScreen({super.key});

  @override
  State<WelcomeScreen> createState() => _WelcomeScreenState();
}

class _WelcomeScreenState extends State<WelcomeScreen> {
  late final _name = TextEditingController(text: AppScope.of(context).displayName);
  late final _server = TextEditingController(text: AppScope.of(context).backendUrl);
  final _group = TextEditingController(text: 'Family');
  bool _busy = false;

  Future<void> _run(Future<void> Function() action) async {
    final s = AppScope.of(context);
    if (_name.text.trim().isEmpty) {
      showError(context, 'Choose a name first — it is only shown to people in your group.');
      return;
    }
    setState(() => _busy = true);
    try {
      await s.setDisplayName(_name.text);
      await action();
    } catch (e) {
      if (mounted) showError(context, describeError(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _create() => _run(() async {
        final s = AppScope.of(context);
        await s.setBackendUrl(_server.text);
        await s.createGroup(_group.text);
      });

  Future<void> _join() async {
    final link = await Navigator.of(context).push<String>(MaterialPageRoute(builder: (_) => const ScanScreen()));
    if (link == null || !mounted) return;
    await _run(() => AppScope.of(context).joinWithLink(link));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(24),
          children: [
            const SizedBox(height: 24),
            Icon(Icons.location_on_rounded, size: 56, color: theme.colorScheme.primary),
            const SizedBox(height: 12),
            Text('OpenLocate', style: theme.textTheme.headlineMedium, textAlign: TextAlign.center),
            const SizedBox(height: 8),
            Text(
              'Private location sharing. Your location is encrypted on this phone; only people you pick can read it.',
              style: theme.textTheme.bodyMedium,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 32),
            TextField(
              controller: _name,
              textCapitalization: TextCapitalization.words,
              decoration: const InputDecoration(labelText: 'Your name', helperText: 'Visible only to members of your group', border: OutlineInputBorder()),
            ),
            const SizedBox(height: 32),
            Text('Join someone', style: theme.textTheme.titleMedium),
            const SizedBox(height: 8),
            FilledButton.icon(
              onPressed: _busy ? null : _join,
              icon: const Icon(Icons.qr_code_scanner),
              label: const Text('Scan an invitation'),
            ),
            const SizedBox(height: 32),
            Text('Or start a new group', style: theme.textTheme.titleMedium),
            const SizedBox(height: 8),
            TextField(controller: _group, decoration: const InputDecoration(labelText: 'Group name', border: OutlineInputBorder())),
            const SizedBox(height: 12),
            TextField(
              controller: _server,
              keyboardType: TextInputType.url,
              decoration: const InputDecoration(
                labelText: 'Server',
                hintText: 'https://openlocate.example.workers.dev',
                helperText: 'Your OpenLocate backend. People you invite use it automatically.',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            OutlinedButton.icon(
              onPressed: _busy ? null : _create,
              icon: const Icon(Icons.group_add),
              label: const Text('Create group'),
            ),
            if (_busy) const Padding(padding: EdgeInsets.only(top: 24), child: Center(child: CircularProgressIndicator())),
          ],
        ),
      ),
    );
  }
}
