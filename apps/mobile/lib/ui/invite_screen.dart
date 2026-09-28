import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../main.dart';
import 'widgets.dart';

/// Shows a single-use, 10-minute invitation as a QR code and a copyable link.
class InviteScreen extends StatefulWidget {
  const InviteScreen({super.key});

  @override
  State<InviteScreen> createState() => _InviteScreenState();
}

class _InviteScreenState extends State<InviteScreen> {
  String? _link;
  DateTime? _expires;
  Timer? _tick;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _create());
    _tick = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  Future<void> _create() async {
    setState(() => _link = null);
    try {
      final link = await AppScope.of(context).createInviteLink();
      setState(() {
        _link = link;
        _expires = DateTime.now().add(const Duration(minutes: 10));
      });
    } catch (e) {
      if (mounted) showError(context, describeError(e));
    }
  }

  @override
  Widget build(BuildContext context) {
    final left = _expires?.difference(DateTime.now());
    final expired = left != null && left.isNegative;
    return Scaffold(
      appBar: AppBar(title: const Text('Invite someone')),
      body: ListView(
        padding: const EdgeInsets.all(24),
        children: [
          const Text('Let them scan this code with OpenLocate. It works once and expires in 10 minutes.', textAlign: TextAlign.center),
          const SizedBox(height: 24),
          Center(
            child: _link == null
                ? const Padding(padding: EdgeInsets.all(80), child: CircularProgressIndicator())
                : Opacity(
                    opacity: expired ? 0.15 : 1,
                    child: Container(
                      color: Colors.white,
                      padding: const EdgeInsets.all(12),
                      child: QrImageView(data: _link!, size: 260),
                    ),
                  ),
          ),
          const SizedBox(height: 16),
          if (left != null)
            Text(
              expired ? 'Expired' : 'Expires in ${left.inMinutes}:${(left.inSeconds % 60).toString().padLeft(2, '0')}',
              textAlign: TextAlign.center,
            ),
          const SizedBox(height: 16),
          if (_link != null && !expired)
            OutlinedButton.icon(
              onPressed: () {
                Clipboard.setData(ClipboardData(text: _link!));
                showError(context, 'Link copied. Send it privately — anyone with it can join once.');
              },
              icon: const Icon(Icons.copy),
              label: const Text('Copy link instead'),
            ),
          if (expired) FilledButton(onPressed: _create, child: const Text('New invitation')),
          const SizedBox(height: 24),
          Text(
            'Joining does not share anything. Each person chooses who can see them.',
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ),
    );
  }
}
