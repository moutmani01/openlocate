import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

/// Scans an invitation QR code, or accepts a pasted invite link. Pops with the link text.
class ScanScreen extends StatefulWidget {
  const ScanScreen({super.key});

  @override
  State<ScanScreen> createState() => _ScanScreenState();
}

class _ScanScreenState extends State<ScanScreen> {
  bool _done = false;

  void _finish(String value) {
    if (_done || !value.trim().startsWith('openlocate://invite')) return;
    _done = true;
    Navigator.of(context).pop(value.trim());
  }

  Future<void> _paste() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text ?? '';
    if (text.trim().startsWith('openlocate://invite')) {
      _finish(text);
    } else if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('The clipboard does not contain an OpenLocate invitation.')));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Scan invitation')),
      body: Column(
        children: [
          Expanded(
            child: MobileScanner(
              onDetect: (capture) {
                for (final b in capture.barcodes) {
                  final v = b.rawValue;
                  if (v != null) _finish(v);
                }
              },
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              children: [
                const Text('Ask a group member to open “Invite” and show you the QR code.'),
                const SizedBox(height: 12),
                OutlinedButton.icon(onPressed: _paste, icon: const Icon(Icons.content_paste), label: const Text('Paste invite link instead')),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
