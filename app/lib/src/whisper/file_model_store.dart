import 'dart:io';

import 'package:crypto/crypto.dart' as crypto;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:transcript_core/transcript_core.dart';

/// A [ModelFileStore] over the app's documents directory.
///
/// A model is a large file that must survive a killed download and a relaunch, so it
/// lives on disk with a partial-file convention: bytes accumulate in `<id>.bin.part`,
/// and the download is renamed to `<id>.bin` only once it has passed its integrity check.
/// Nothing reads a `.part` file as a model, so a half-download can never be mistaken for
/// a complete one.
class FileModelStore implements ModelFileStore {
  FileModelStore({Directory? root}) : _rootOverride = root;

  final Directory? _rootOverride;

  Future<Directory> _dir() async {
    final base = _rootOverride ?? await getApplicationSupportDirectory();
    final dir = Directory(p.join(base.path, 'whisper-models'));
    if (!dir.existsSync()) dir.createSync(recursive: true);
    return dir;
  }

  Future<File> _part(String id) async =>
      File(p.join((await _dir()).path, '$id.bin.part'));

  Future<File> _complete(String id) async =>
      File(p.join((await _dir()).path, '$id.bin'));

  @override
  Future<int> bytesOnDisk(String modelId) async {
    final part = await _part(modelId);
    return part.existsSync() ? part.lengthSync() : 0;
  }

  @override
  Future<void> append(String modelId, List<int> bytes) async {
    final part = await _part(modelId);
    await part.writeAsBytes(bytes, mode: FileMode.append, flush: true);
  }

  @override
  Future<String> sha256(String modelId) async {
    final part = await _part(modelId);
    if (!part.existsSync()) return '';
    // Streamed rather than read-whole: a model is hundreds of megabytes and loading it
    // into memory to hash it would risk an out-of-memory kill on a phone.
    final digest = await crypto.sha256.bind(part.openRead()).first;
    return digest.toString();
  }

  @override
  Future<void> discard(String modelId) async {
    final part = await _part(modelId);
    if (part.existsSync()) await part.delete();
  }

  @override
  Future<void> markComplete(String modelId) async {
    final part = await _part(modelId);
    if (part.existsSync()) await part.rename((await _complete(modelId)).path);
  }

  @override
  Future<bool> isComplete(String modelId) async =>
      (await _complete(modelId)).existsSync();

  /// Absolute path to a finished model, or null. What the native engine is handed.
  Future<String?> completedPath(String modelId) async {
    final file = await _complete(modelId);
    return file.existsSync() ? file.path : null;
  }
}
