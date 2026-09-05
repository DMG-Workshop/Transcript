import '../capabilities.dart';
import '../connection.dart';
import '../provider.dart';

/// Deterministic providers for tests, for the widget layer before any key exists, and for
/// the simulator, where there is no microphone worth using.
class FakeStructuringProvider extends StructuringProvider {
  FakeStructuringProvider({
    required this.response,
    this.connection,
    this.delay = Duration.zero,
  });

  final String response;
  final ConnectionResult? connection;
  final Duration delay;

  final List<StructureRequest> requests = [];

  @override
  ProviderId get id => const ProviderId('fake-structuring');

  @override
  String get displayName => 'Fake structuring provider';

  @override
  ProviderCapabilities get capabilities => const ProviderCapabilities(
        acceptsAudio: false,
        acceptsText: true,
        nativeJsonSchema: true,
        requiresApiKey: false,
        contextWindowTokens: 200000,
      );

  @override
  Future<ConnectionResult> test() async =>
      connection ?? ConnectionResult.success(summary: 'Connected · fake');

  @override
  Future<StructureResponse> structure(StructureRequest request) async {
    requests.add(request);
    if (delay > Duration.zero) await Future<void>.delayed(delay);
    return StructureResponse(
        rawText: response, inputTokens: 100, outputTokens: 50);
  }
}

class FakeTranscriptionProvider extends TranscriptionProvider {
  FakeTranscriptionProvider({this.segments = const []});

  final List<TranscriptSegment> segments;
  final List<TranscribeRequest> requests = [];

  @override
  ProviderId get id => const ProviderId('fake-transcription');

  @override
  String get displayName => 'Fake transcription provider';

  @override
  ProviderCapabilities get capabilities => const ProviderCapabilities(
        acceptsAudio: true,
        acceptsText: false,
        nativeJsonSchema: false,
        requiresApiKey: false,
        runsOnDevice: true,
        maxRequestBytes: 25 * 1024 * 1024,
      );

  @override
  Future<ConnectionResult> test() async =>
      ConnectionResult.success(summary: 'Ready · fake');

  @override
  Future<List<TranscriptSegment>> transcribe(TranscribeRequest request) async {
    requests.add(request);
    return segments.map((s) => s.shifted(request.offsetMs)).toList();
  }
}
