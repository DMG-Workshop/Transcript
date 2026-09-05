import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'src/settings/settings_screen.dart';

void main() {
  runApp(const ProviderScope(child: TranscriptApp()));
}

/// Phase 0 boots straight into settings: there is nothing to record with yet, and the
/// point of this phase is proving that every provider is reachable from a real device.
class TranscriptApp extends StatelessWidget {
  const TranscriptApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Transcript',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorSchemeSeed: const Color(0xFF0B6A6A),
        brightness: Brightness.light,
        useMaterial3: true,
      ),
      darkTheme: ThemeData(
        colorSchemeSeed: const Color(0xFF0B6A6A),
        brightness: Brightness.dark,
        useMaterial3: true,
      ),
      home: const SettingsScreen(),
    );
  }
}
