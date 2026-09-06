import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:transcript_app/src/whisper/file_model_store.dart';

void main() {
  late Directory tmp;
  late FileModelStore store;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('whisper_test');
    store = FileModelStore(root: tmp);
  });

  tearDown(() => tmp.deleteSync(recursive: true));

  test('appended bytes accumulate and are counted for resuming', () async {
    await store.append('base', [1, 2, 3]);
    await store.append('base', [4, 5]);
    expect(await store.bytesOnDisk('base'), 5);
  });

  test('a partial download is never seen as a complete model', () async {
    await store.append('base', [1, 2, 3]);
    expect(await store.isComplete('base'), isFalse,
        reason: 'a half-download must not be mistaken for a usable model');
    expect(await store.completedPath('base'), isNull);
  });

  test('completion renames the part file into the real one', () async {
    await store.append('base', [1, 2, 3]);
    await store.markComplete('base');

    expect(await store.isComplete('base'), isTrue);
    expect(await store.completedPath('base'), isNotNull);
    // Resuming a completed model starts fresh, because the .part file is gone.
    expect(await store.bytesOnDisk('base'), 0);
  });

  test('the hash matches a known SHA-256, streamed rather than read whole', () async {
    final bytes = List.generate(5000, (i) => i % 256);
    await store.append('base', bytes);

    expect(await store.sha256('base'), sha256.convert(bytes).toString(),
        reason: 'a corrupt model must be detectable by hash');
  });

  test('discarding removes the partial file so a retry starts clean', () async {
    await store.append('base', [1, 2, 3]);
    await store.discard('base');
    expect(await store.bytesOnDisk('base'), 0);
  });

  test('the hash of a missing file is empty, not an error', () async {
    expect(await store.sha256('never-downloaded'), '');
  });
}
