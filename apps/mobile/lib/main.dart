import 'package:flutter/material.dart';
import 'package:sodium/sodium_sumo.dart';

import 'crypto/ol_crypto.dart';
import 'state/app_state.dart';
import 'ui/home_screen.dart';
import 'ui/welcome_screen.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final state = AppState(OlCrypto(SodiumSumoInit.init()));
  await state.init();
  runApp(OpenLocateApp(state: state));
}

/// Makes [AppState] available to every screen and rebuilds dependents when it changes.
class AppScope extends InheritedNotifier<AppState> {
  const AppScope({super.key, required AppState state, required super.child}) : super(notifier: state);

  static AppState of(BuildContext context) => context.dependOnInheritedWidgetOfExactType<AppScope>()!.notifier!;
}

class OpenLocateApp extends StatelessWidget {
  const OpenLocateApp({super.key, required this.state});

  final AppState state;

  @override
  Widget build(BuildContext context) {
    return AppScope(
      state: state,
      child: MaterialApp(
        title: 'OpenLocate',
        theme: ThemeData(colorSchemeSeed: const Color(0xFF1B6EF3), useMaterial3: true),
        darkTheme: ThemeData(colorSchemeSeed: const Color(0xFF1B6EF3), brightness: Brightness.dark, useMaterial3: true),
        home: const _Root(),
      ),
    );
  }
}

class _Root extends StatelessWidget {
  const _Root();

  @override
  Widget build(BuildContext context) {
    final s = AppScope.of(context);
    return s.inGroup ? const HomeScreen() : const WelcomeScreen();
  }
}
