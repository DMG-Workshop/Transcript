import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'src/onboarding/onboarding_screen.dart';
import 'src/privacy/crash_log.dart';
import 'src/recording/recording_controller.dart';
import 'src/screens/record_screen.dart';
import 'src/settings/provider_config.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Diagnostics first, so a failure anywhere in the rest of startup is itself recorded
  // rather than lost. Installing the handlers is also what makes the redactor exist,
  // and the key store depends on it.
  final diagnostics = await installCrashReporting();

  // Settings are needed before the first frame — which provider to use is not something
  // to discover halfway through a recording.
  final prefs = await SharedPreferences.getInstance();

  runApp(
    ProviderScope(
      overrides: [
        settingsStoreProvider.overrideWithValue(SettingsStore(prefs)),
        diagnosticsProvider.overrideWithValue(diagnostics),
      ],
      child: const TranscriptApp(),
    ),
  );
}

class TranscriptApp extends ConsumerStatefulWidget {
  const TranscriptApp({super.key});

  static const Color _seed = Color(0xFF0B6A6A);

  @override
  ConsumerState<TranscriptApp> createState() => _TranscriptAppState();
}

class _TranscriptAppState extends ConsumerState<TranscriptApp> {
  late bool _needsOnboarding = !ref.read(settingsStoreProvider).hasOnboarded;

  Future<void> _finishOnboarding() async {
    await ref.read(settingsStoreProvider).setOnboarded();
    if (mounted) setState(() => _needsOnboarding = false);
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Transcript',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorSchemeSeed: TranscriptApp._seed,
        brightness: Brightness.light,
        useMaterial3: true,
      ),
      darkTheme: ThemeData(
        colorSchemeSeed: TranscriptApp._seed,
        brightness: Brightness.dark,
        useMaterial3: true,
      ),
      home: _needsOnboarding
          ? OnboardingScreen(onDone: _finishOnboarding)
          : const RecordScreen(),
    );
  }
}
