import 'package:flutter/material.dart';
import 'package:sodium/sodium_sumo.dart';

import 'config.dart';
import 'crypto/ol_crypto.dart';
import 'location/tracker.dart';
import 'state/app_state.dart';
import 'ui/home_screen.dart';
import 'ui/welcome_screen.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  Tracker.initPort();
  final AppState state;
  try {
    state = AppState(OlCrypto(await SodiumSumoInit.init()));
    await state.init();
  } catch (e) {
    // Without this, a failure here leaves the launch screen up for ever with no explanation.
    runApp(StartupErrorApp(error: e));
    return;
  }
  runApp(OpenLocateApp(state: state));
}

/// Shown instead of the app when start-up fails, so the problem can be reported.
class StartupErrorApp extends StatelessWidget {
  const StartupErrorApp({super.key, required this.error});

  final Object error;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'OpenLocate',
      theme: ThemeData(colorSchemeSeed: const Color(0xFF1B6EF3), useMaterial3: true),
      darkTheme: ThemeData(colorSchemeSeed: const Color(0xFF1B6EF3), brightness: Brightness.dark, useMaterial3: true),
      home: Scaffold(
        body: SafeArea(
          child: ListView(
            padding: const EdgeInsets.all(24),
            children: [
              const Icon(Icons.error_outline, size: 48),
              const SizedBox(height: 16),
              const Text('OpenLocate could not start', style: TextStyle(fontSize: 22), textAlign: TextAlign.center),
              const SizedBox(height: 12),
              const Text(
                'Nothing was shared. Please report this with the text below; it contains no location or keys.',
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 16),
              SelectableText('${AppConfig.appVersion}\n$error', style: const TextStyle(fontFamily: 'monospace', fontSize: 12)),
            ],
          ),
        ),
      ),
    );
  }
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
