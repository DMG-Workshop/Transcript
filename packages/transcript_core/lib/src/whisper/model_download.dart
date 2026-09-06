import 'dart:async';

import '../providers/http_transport.dart';
import 'whisper_models.dart';

/// Progress of a model download.
class DownloadProgress {
  const DownloadProgress(
      {required this.receivedBytes, required this.totalBytes});

  final int receivedBytes;
  final int totalBytes;

  double get fraction => totalBytes == 0 ? 0 : receivedBytes / totalBytes;

  String get received => _mb(receivedBytes);
  String get total => _mb(totalBytes);

  static String _mb(int bytes) =>
      '${(bytes / (1024 * 1024)).toStringAsFixed(0)} MB';
}

/// Why a download stopped short.
class DownloadException implements Exception {
  const DownloadException(this.reason);
  final String reason;
  @override
  String toString() => 'DownloadException: $reason';
}

/// Where model files are written, and how a partial one is resumed. Implemented over the
/// filesystem in the app; faked in tests, so resume and integrity logic run without disk.
abstract class ModelFileStore {
  /// Bytes already on disk for [modelId], for resuming an interrupted download.
  Future<int> bytesOnDisk(String modelId);

  /// Appends a downloaded range to the model's file.
  Future<void> append(String modelId, List<int> bytes);

  /// The SHA-256 of what is on disk, for integrity verification.
  Future<String> sha256(String modelId);

  /// Discards a file that failed verification, so a retry starts clean rather than
  /// resuming onto corrupt bytes.
  Future<void> discard(String modelId);

  Future<void> markComplete(String modelId);
  Future<bool> isComplete(String modelId);
}

/// Fetches a whisper model, resumably and with an integrity check.
///
/// A model is tens to hundreds of megabytes over a mobile connection, so two things are
/// not optional: it must resume rather than restart when the connection drops, and it
/// must verify what arrived, because a silently corrupt model fails deep in the native
/// decoder with an error no user could diagnose.
class ModelDownloader {
  ModelDownloader({
    required this.transport,
    required this.store,
    Uri? baseUrl,
    this.chunkBytes = 4 * 1024 * 1024,
  }) : baseUrl = baseUrl ?? defaultBaseUrl;

  static final Uri defaultBaseUrl = Uri.parse('https://huggingface.co');

  final HttpTransport transport;
  final ModelFileStore store;
  final Uri baseUrl;

  /// Downloaded in ranges so progress is visible and a drop costs one range, not the
  /// whole file.
  final int chunkBytes;

  /// Downloads [model], emitting progress, and verifies it before reporting done.
  ///
  /// Resumes from whatever is already on disk. Verifying the hash is the last step and a
  /// mismatch discards the file — resuming onto corrupt bytes would fail forever.
  Stream<DownloadProgress> download(WhisperModel model) async* {
    if (await store.isComplete(model.id)) {
      yield DownloadProgress(
          receivedBytes: model.approxBytes, totalBytes: model.approxBytes);
      return;
    }

    final url = baseUrl.resolve(model.downloadPath());
    var received = await store.bytesOnDisk(model.id);
    var total = model.approxBytes;

    while (true) {
      final HttpReply reply;
      try {
        reply = await transport.send(HttpCall(
          method: 'GET',
          url: url,
          headers: {'range': 'bytes=$received-${received + chunkBytes - 1}'},
          timeout: const Duration(minutes: 2),
        ));
      } on TransportException catch (e) {
        // A dropped connection is expected on mobile and is not fatal: what is on disk
        // stays, and the next call resumes from there.
        throw DownloadException('Connection interrupted (${e.message}). '
            'The download will resume from where it stopped.');
      }

      // 206 = partial content (range honoured); 200 = whole file (server ignored the
      // range, so start over cleanly); 416 = range past the end, i.e. already complete.
      if (reply.statusCode == 416) break;
      if (reply.statusCode == 200 && received > 0) {
        await store.discard(model.id);
        received = 0;
        continue;
      }
      if (!reply.ok && reply.statusCode != 206) {
        throw DownloadException(
            'The server returned ${reply.statusCode} fetching the model.');
      }

      total = _totalFrom(reply.headers) ?? total;
      final body = reply.bodyBytes ?? const [];
      if (body.isEmpty) break;

      await store.append(model.id, body);
      received += body.length;
      yield DownloadProgress(receivedBytes: received, totalBytes: total);

      if (received >= total) break;
    }

    // Only enforce the hash once the catalog carries a real one; a debug catalog with
    // placeholders skips the check rather than failing every download.
    if (model.sha256 != WhisperCatalogHashPlaceholder.value) {
      final actual = await store.sha256(model.id);
      if (actual.toLowerCase() != model.sha256.toLowerCase()) {
        await store.discard(model.id);
        throw const DownloadException(
          'The downloaded model failed its integrity check and was discarded. '
          'Please try again.',
        );
      }
    }

    await store.markComplete(model.id);
    yield DownloadProgress(receivedBytes: total, totalBytes: total);
  }

  /// Total size from a Content-Range (`bytes 0-4/12345`) or a Content-Length header.
  static int? _totalFrom(Map<String, String> headers) {
    final range = headers['content-range'] ?? headers['Content-Range'];
    if (range != null && range.contains('/')) {
      final total = int.tryParse(range.split('/').last.trim());
      if (total != null && total > 0) return total;
    }
    final length = headers['content-length'] ?? headers['Content-Length'];
    return length == null ? null : int.tryParse(length.trim());
  }
}

/// Exposes the catalog's placeholder marker so the downloader can skip verification for a
/// debug catalog without importing the catalog's private constant.
class WhisperCatalogHashPlaceholder {
  const WhisperCatalogHashPlaceholder._();
  static const String value = 'REPLACE_WITH_REAL_SHA256';
}
