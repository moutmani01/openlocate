import 'package:flutter/material.dart';

import '../backend/backend_provider.dart';

void showError(BuildContext context, String message) {
  ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
}

String describeError(Object e) {
  if (e is FormatException) return e.message;
  if (e is BackendException) {
    return switch (e.code) {
      'invalid_invitation' => 'This invitation is invalid, expired or already used. Ask for a new one.',
      'not_a_member' => 'You are not a member of this group.',
      'group_full' => 'This group is full.',
      'rate_limited' => 'Too many requests — try again in a moment.',
      _ => 'Server error (${e.status} ${e.code})',
    };
  }
  return 'Could not reach the server. Check the address and your connection.';
}

/// Round avatar with initials, colored per person.
class Avatar extends StatelessWidget {
  const Avatar({super.key, required this.name, required this.id, this.size = 40, this.online = false});

  final String name;
  final String id;
  final double size;
  final bool online;

  static Color colorFor(String id) {
    const colors = [Color(0xFF1B6EF3), Color(0xFFE8453C), Color(0xFF0F9D58), Color(0xFFF4A300), Color(0xFF8E44AD), Color(0xFF00897B), Color(0xFFD81B60)];
    return colors[id.codeUnits.fold<int>(0, (a, b) => a + b) % colors.length];
  }

  @override
  Widget build(BuildContext context) {
    final initials = name.trim().isEmpty ? '?' : name.trim().split(RegExp(r'\s+')).take(2).map((w) => w[0].toUpperCase()).join();
    return Stack(
      children: [
        CircleAvatar(
          radius: size / 2,
          backgroundColor: colorFor(id),
          child: Text(initials, style: TextStyle(color: Colors.white, fontSize: size * 0.38, fontWeight: FontWeight.w600)),
        ),
        if (online)
          Positioned(
            right: 0,
            bottom: 0,
            child: Container(
              width: size * 0.3,
              height: size * 0.3,
              decoration: BoxDecoration(color: const Color(0xFF0F9D58), shape: BoxShape.circle, border: Border.all(color: Colors.white, width: 2)),
            ),
          ),
      ],
    );
  }
}
