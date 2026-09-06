import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:transcript_whisper_native/transcript_whisper_native.dart';

/// These tests load the *actually compiled* native library rather than
/// mocking the FFI boundary, so they only run once `tool/build_native_test_lib.sh`
/// has produced a shared library for the host platform (CI does this before
/// `dart test`; run it locally the same way before `dart test`).
///
/// There is no whisper.cpp model file available in this environment (models
/// are tens to hundreds of megabytes and fetched from the network at
/// runtime), so these tests exercise everything that does not require a
/// successfully loaded model: symbol resolution, string marshaling in both
/// directions, and the native error-JSON path.
void main() {
  final libraryPath = _findBuiltLibrary();

  group('transcript_whisper_native (real compiled library)', () {
    test(
      'library was built for this host platform',
      () {},
      skip: libraryPath == null
          ? 'Run tool/build_native_test_lib.sh first (needs cmake + a C++ compiler).'
          : false,
    );

    if (libraryPath == null) {
      return;
    }

    test('reports a version string', () {
      final version = whisperNativeVersion(libraryPath: libraryPath);
      expect(version, contains('transcript_whisper_native'));
      expect(version, contains('whisper.cpp'));
    });

    test('a missing model file surfaces as a WhisperNativeException', () {
      final wavPath = _writeMinimalSilentWav();
      addTearDown(() => File(wavPath).deleteSync());

      expect(
        () => transcribeWavSync(
          modelPath: '/nonexistent/model.bin',
          wavPath: wavPath,
          libraryPath: libraryPath,
        ),
        throwsA(
          isA<WhisperNativeException>().having(
            (e) => e.message,
            'message',
            contains('failed to load whisper model'),
          ),
        ),
      );
    });

    test('release is safe to call with nothing loaded', () {
      expect(
        () => releaseWhisperModel(libraryPath: libraryPath),
        returnsNormally,
      );
    });
  });
}

/// Locates the shared library produced by [tool/build_native_test_lib.sh],
/// or returns null if it hasn't been built.
String? _findBuiltLibrary() {
  final packageRoot = _packageRoot();
  final candidates = [
    p.join(
      packageRoot,
      'build',
      'native_test',
      'libtranscript_whisper_native.so',
    ),
    p.join(
      packageRoot,
      'build',
      'native_test',
      'libtranscript_whisper_native.dylib',
    ),
    p.join(
      packageRoot,
      'build',
      'native_test',
      'transcript_whisper_native.dll',
    ),
  ];
  for (final candidate in candidates) {
    if (File(candidate).existsSync()) {
      return candidate;
    }
  }
  return null;
}

String _packageRoot() {
  var dir = Directory.current;
  while (true) {
    if (File(p.join(dir.path, 'pubspec.yaml')).existsSync()) {
      return dir.path;
    }
    final parent = dir.parent;
    if (parent.path == dir.path) {
      throw StateError(
        'Could not locate package root from ${Directory.current.path}',
      );
    }
    dir = parent;
  }
}

/// A one-second, silent, 16 kHz mono 16-bit PCM WAV file — exactly the
/// format the native decoder requires, so this only ever fails on the model
/// load, never the WAV validation.
String _writeMinimalSilentWav() {
  const sampleRate = 16000;
  const seconds = 1;
  final samples = List<int>.filled(sampleRate * seconds, 0);
  final dataBytes = samples.length * 2;

  final bytes = BytesBuilder();
  void writeAscii(String s) => bytes.add(s.codeUnits);
  void writeU32(int v) => bytes.add([
    v & 0xff,
    (v >> 8) & 0xff,
    (v >> 16) & 0xff,
    (v >> 24) & 0xff,
  ]);
  void writeU16(int v) => bytes.add([v & 0xff, (v >> 8) & 0xff]);

  writeAscii('RIFF');
  writeU32(36 + dataBytes);
  writeAscii('WAVE');
  writeAscii('fmt ');
  writeU32(16);
  writeU16(1); // PCM
  writeU16(1); // mono
  writeU32(sampleRate);
  writeU32(sampleRate * 2); // byte rate
  writeU16(2); // block align
  writeU16(16); // bits per sample
  writeAscii('data');
  writeU32(dataBytes);
  for (final sample in samples) {
    writeU16(sample & 0xffff);
  }

  final path = p.join(
    Directory.systemTemp.createTempSync('transcript_whisper_native_test_').path,
    'silence.wav',
  );
  File(path).writeAsBytesSync(bytes.toBytes());
  return path;
}
