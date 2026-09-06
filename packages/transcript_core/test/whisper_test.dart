import 'package:test/test.dart';
import 'package:transcript_core/transcript_core.dart';

/// In-memory model store: bytes live in a buffer, so resume, discard and completion all
/// run without touching disk.
class FakeModelStore implements ModelFileStore {
  final Map<String, List<int>> _files = {};
  final Set<String> _complete = {};
  String Function(List<int>)? hasher;

  @override
  Future<int> bytesOnDisk(String modelId) async => _files[modelId]?.length ?? 0;

  @override
  Future<void> append(String modelId, List<int> bytes) async =>
      (_files[modelId] ??= []).addAll(bytes);

  @override
  Future<String> sha256(String modelId) async =>
      (hasher ?? _defaultHash)(_files[modelId] ?? const []);

  @override
  Future<void> discard(String modelId) async {
    _files.remove(modelId);
    _complete.remove(modelId);
  }

  @override
  Future<void> markComplete(String modelId) async => _complete.add(modelId);

  @override
  Future<bool> isComplete(String modelId) async => _complete.contains(modelId);

  int totalFor(String modelId) => _files[modelId]?.length ?? 0;

  static String _defaultHash(List<int> bytes) => 'len${bytes.length}';
}

/// Serves a fixed body in ranges, honouring the Range header.
class RangeServingTransport implements HttpTransport {
  RangeServingTransport(this.body,
      {this.ignoreRange = false, this.failFirst = 0});

  final List<int> body;
  final bool ignoreRange;
  int failFirst;

  final List<HttpCall> calls = [];

  @override
  Future<HttpReply> send(HttpCall call) async {
    calls.add(call);
    if (failFirst > 0) {
      failFirst--;
      throw const TransportException(TransportFailure.refused, 'dropped');
    }

    if (ignoreRange) {
      return HttpReply(200, '',
          bodyBytes: body, headers: {'content-length': '${body.length}'});
    }

    final range = call.headers['range'] ?? 'bytes=0-';
    final match = RegExp(r'bytes=(\d+)-(\d+)?').firstMatch(range)!;
    final start = int.parse(match.group(1)!);
    if (start >= body.length) {
      return const HttpReply(416, '');
    }
    final end = match.group(2) == null
        ? body.length - 1
        : int.parse(match.group(2)!).clamp(0, body.length - 1);
    final slice = body.sublist(start, end + 1);

    return HttpReply(
      206,
      '',
      bodyBytes: slice,
      headers: {'content-range': 'bytes $start-$end/${body.length}'},
    );
  }
}

void main() {
  final model = WhisperCatalog.recommended;

  List<int> payload(int n) => List.generate(n, (i) => i % 256);

  ModelDownloader downloader(
    HttpTransport transport,
    FakeModelStore store, {
    int chunk = 100,
  }) =>
      ModelDownloader(transport: transport, store: store, chunkBytes: chunk);

  group('catalog', () {
    test('offers a short, described list', () {
      expect(WhisperCatalog.models, isNotEmpty);
      expect(WhisperCatalog.models.length, lessThanOrEqualTo(4),
          reason:
              'the point is a defensible default, not the whole whisper zoo');
      for (final m in WhisperCatalog.models) {
        expect(m.approxBytes, greaterThan(0));
        expect(m.quality.description, isNotEmpty);
      }
    });

    test('the default is not the smallest model', () {
      expect(WhisperCatalog.recommended.id, isNot('tiny'),
          reason: 'tiny is noticeably worse on real meetings');
    });

    test('placeholder hashes are flagged so they cannot ship silently', () {
      expect(WhisperCatalog.verified, isFalse,
          reason: 'the catalog still carries placeholder hashes');
    });

    test('a model resolves to the canonical ggml distribution path', () {
      expect(WhisperCatalog.byId('base')!.downloadPath(),
          contains('ggml-base.bin'));
    });
  });

  group('downloading', () {
    test('fetches a model in ranges and reports progress to completion',
        () async {
      final store = FakeModelStore();
      final transport = RangeServingTransport(payload(350));

      final progress =
          await downloader(transport, store).download(model).toList();

      expect(store.totalFor(model.id), 350);
      expect(await store.isComplete(model.id), isTrue);
      expect(progress.last.fraction, 1.0);
      expect(transport.calls.length, greaterThan(1),
          reason: 'a large file is fetched in ranges, not one giant request');
    });

    test('resumes from what is already on disk rather than restarting',
        () async {
      final store = FakeModelStore();
      await store.append(model.id, payload(200)); // a prior partial download

      final transport = RangeServingTransport(payload(350));
      await downloader(transport, store).download(model).toList();

      final firstRange = transport.calls.first.headers['range'];
      expect(firstRange, 'bytes=200-299',
          reason: 'a dropped 350 MB download must not start over');
      expect(store.totalFor(model.id), 350);
    });

    test(
        'a server that ignores the range restarts cleanly instead of corrupting',
        () async {
      final store = FakeModelStore();
      await store.append(model.id, payload(50));

      final transport = RangeServingTransport(payload(120), ignoreRange: true);
      await downloader(transport, store, chunk: 1000).download(model).toList();

      expect(store.totalFor(model.id), 120,
          reason:
              'appending a whole-file response onto a partial one would corrupt it');
    });

    test('a connection drop surfaces as resumable, not as data loss', () async {
      final store = FakeModelStore();
      final transport = RangeServingTransport(payload(350), failFirst: 1);

      await expectLater(
        downloader(transport, store).download(model).toList(),
        throwsA(isA<DownloadException>()
            .having((e) => e.reason, 'reason', contains('resume'))),
      );
    });

    test('a completed model is not downloaded again', () async {
      final store = FakeModelStore();
      await store.markComplete(model.id);
      final transport = RangeServingTransport(payload(350));

      await downloader(transport, store).download(model).toList();
      expect(transport.calls, isEmpty, reason: 'the file is already here');
    });

    test('a corrupt download fails its integrity check and is discarded',
        () async {
      // Give the model a real (non-placeholder) hash that the bytes will not match.
      const bad = WhisperModel(
        id: 'base',
        label: 'Base',
        approxBytes: 350,
        quality: WhisperQuality.balanced,
        multilingual: true,
        sha256: 'deadbeef',
      );
      final store = FakeModelStore()..hasher = (_) => 'not_deadbeef';
      final transport = RangeServingTransport(payload(350));

      await expectLater(
        downloader(transport, store).download(bad).toList(),
        throwsA(isA<DownloadException>()
            .having((e) => e.reason, 'reason', contains('integrity'))),
      );
      expect(await store.isComplete(bad.id), isFalse);
      expect(store.totalFor(bad.id), 0,
          reason: 'corrupt bytes must not be kept');
    });

    test('a matching hash completes and is kept', () async {
      const good = WhisperModel(
        id: 'base',
        label: 'Base',
        approxBytes: 350,
        quality: WhisperQuality.balanced,
        multilingual: true,
        sha256: 'GOOD',
      );
      final store = FakeModelStore()..hasher = (_) => 'good';
      final transport = RangeServingTransport(payload(350));

      await downloader(transport, store).download(good).toList();
      expect(await store.isComplete(good.id), isTrue);
    });
  });

  group('the offline provider', () {
    test('reports itself as on-device, no key, accepts audio', () {
      final provider = WhisperTranscriptionProvider(
        engine: _FakeEngine(ready: true),
        model: model,
      );

      expect(provider.capabilities.runsOnDevice, isTrue);
      expect(provider.capabilities.requiresApiKey, isFalse);
      expect(provider.capabilities.acceptsAudio, isTrue);
    });

    test('is not ready until the model is downloaded', () async {
      final provider = WhisperTranscriptionProvider(
        engine: _FakeEngine(ready: false),
        model: model,
      );

      final result = await provider.test();
      expect(result.ok, isFalse);
      expect(result.remedy, contains('Download'));
      expect(result.remedy, contains('${model.approxMegabytes.round()} MB'));
    });

    test('transcribes offline and shifts offsets to absolute positions',
        () async {
      final provider = WhisperTranscriptionProvider(
        engine: _FakeEngine(
          ready: true,
          segments: [
            const TranscriptSegment(
                startMs: 0, endMs: 2000, text: 'hello there'),
          ],
        ),
        model: model,
      );

      final segments = await provider.transcribe(const TranscribeRequest(
        audio: [1, 2, 3],
        mimeType: 'audio/wav',
        offsetMs: 45000,
      ));

      expect(segments.single.startMs, 45000,
          reason: 'whisper offsets are buffer-relative; the recording is not');
      expect(segments.single.text, 'hello there');
    });

    test('transcribing without a downloaded model is a clear error', () async {
      final provider = WhisperTranscriptionProvider(
        engine: _FakeEngine(ready: false),
        model: model,
      );

      await expectLater(
        provider.transcribe(
            const TranscribeRequest(audio: [1], mimeType: 'audio/wav')),
        throwsA(isA<StateError>()),
      );
    });
  });
}

class _FakeEngine implements WhisperEngine {
  _FakeEngine({required this.ready, this.segments = const []});

  final bool ready;
  final List<TranscriptSegment> segments;

  @override
  Future<bool> isModelReady(String modelId) async => ready;

  @override
  Future<String?> modelPath(String modelId) async =>
      ready ? '/models/$modelId.bin' : null;

  @override
  Future<List<TranscriptSegment>> transcribe({
    required String modelPath,
    required List<int> pcm16,
    String? languageHint,
  }) async =>
      segments;
}
