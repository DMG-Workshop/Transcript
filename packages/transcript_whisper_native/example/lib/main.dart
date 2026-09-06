import 'package:flutter/material.dart';
import 'package:transcript_whisper_native/transcript_whisper_native.dart'
    as transcript_whisper_native;

void main() {
  runApp(const MyApp());
}

class MyApp extends StatefulWidget {
  const MyApp({super.key});

  @override
  State<MyApp> createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> {
  late final String version;
  late final Object? error;

  @override
  void initState() {
    super.initState();
    try {
      version = transcript_whisper_native.whisperNativeVersion();
      error = null;
    } catch (e) {
      version = '';
      error = e;
    }
  }

  @override
  Widget build(BuildContext context) {
    const textStyle = TextStyle(fontSize: 20);
    return MaterialApp(
      home: Scaffold(
        appBar: AppBar(title: const Text('transcript_whisper_native')),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Text(
              error == null
                  ? 'Native library loaded:\n$version'
                  : 'Failed to load native library:\n$error',
              style: textStyle,
              textAlign: TextAlign.center,
            ),
          ),
        ),
      ),
    );
  }
}
