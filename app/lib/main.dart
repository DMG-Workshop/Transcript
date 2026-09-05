import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'src/recording/recording_controller.dart';
import 'src/screens/record_screen.dart';
import 'src/settings/provider_config.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Settings are needed before the first frame — which provider to use is not something
  // to discover halfway through a recording.
  final prefs = await SharedPreferences.getInstance();

  runApp(
    ProviderScope(
      overrides: [
        settingsStoreProvider.overrideWithValue(SettingsStore(prefs)),
      ],
      child: const TranscriptApp(),
    ),
  );
}

class TranscriptApp extends StatelessWidget {
  const TranscriptApp({super.key});

  static const Color _seed = Color(0xFF0B6A6A);

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Transcript',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorSchemeSeed: _seed,
        brightness: Brightness.light,
        useMaterial3: true,
      ),
      darkTheme: ThemeData(
        colorSchemeSeed: _seed,
        brightness: Brightness.dark,
        useMaterial3: true,
      ),
      home: const RecordScreen(),
    );
  }
}
