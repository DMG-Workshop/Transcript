import '../../schema/dialects.dart';
import '../capabilities.dart';
import '../connection.dart';
import '../errors.dart';
import '../http_transport.dart';
import '../provider.dart';

/// OpenAI — the only first-party provider that covers both stages, via two different
/// endpoints. Transcription and structuring are still configured independently, so a user
/// can transcribe here and structure elsewhere.
class OpenAiStructuringProvider extends StructuringProvider {
  OpenAiStructuringProvider({
    required HttpTransport transport,
    required String apiKey,
    this.model = 'gpt-4o',
    Uri? baseUrl,
  })  : _transport = transport,
        _apiKey = apiKey,
        _baseUrl = baseUrl ?? Uri.parse('https://api.openai.com');

  final HttpTransport _transport;
  final String _apiKey;
  final Uri _baseUrl;
  final String model;

  @override
  ProviderId get id => const ProviderId('openai');

  @override
  String get displayName => 'OpenAI';

  @override
  ProviderCapabilities get capabilities => const ProviderCapabilities(
        acceptsAudio: false, // this class is the structuring half
        acceptsText: true,
        nativeJsonSchema: true,
        streaming: true,
        contextWindowTokens: 128000,
        maxOutputTokens: 16384,
      );

  Map<String, String> get _headers => {
        'authorization': 'Bearer $_apiKey',
        'accept': 'application/json',
      };

  @override
  Future<ConnectionResult> test() =>
      openAiStyleTest(_transport, _baseUrl, _headers, displayName, model);

  @override
  Future<StructureResponse> structure(StructureRequest request) async {
    final reply = await _transport.send(HttpCall(
      method: 'POST',
      url: _baseUrl.resolve('/v1/chat/completions'),
      headers: _headers,
      timeout: const Duration(minutes: 5),
      jsonBody: {
        'model': model,
        'max_tokens': request.maxOutputTokens,
        'messages': [
          {'role': 'system', 'content': request.systemPrompt},
          for (final turn in request.priorTurns)
            {'role': turn.role, 'content': turn.content},
          {'role': 'user', 'content': request.userContent},
        ],
        'response_format': {
          'type': 'json_schema',
          'json_schema': {
            'name': 'note_document',
            'strict': true,
            'schema': renderSchema(request.schema, SchemaDialect.openAiStrict),
          },
        },
      },
    ));

    if (!reply.ok) {
      throw ProviderException(displayName, reply.statusCode,
          providerErrorMessage(reply.json, reply.body));
    }

    final body = reply.json ?? const {};
    final choices = body['choices'];
    var text = '';
    if (choices is List && choices.isNotEmpty) {
      final message = (choices.first as Map<String, dynamic>)['message'];
      if (message is Map) text = message['content']?.toString() ?? '';
    }

    final usage = (body['usage'] as Map?)?.cast<String, dynamic>();
    return StructureResponse(
      rawText: text,
      inputTokens: usage?['prompt_tokens'] as int?,
      outputTokens: usage?['completion_tokens'] as int?,
      model: body['model'] as String?,
    );
  }
}

/// OpenAI audio transcription. The 25 MB per-request ceiling here is what sets the
/// chunker's byte cap for every cloud configuration.
class OpenAiTranscriptionProvider extends TranscriptionProvider {
  OpenAiTranscriptionProvider({
    required HttpTransport transport,
    required String apiKey,
    this.model = 'whisper-1',
    Uri? baseUrl,
  })  : _transport = transport,
        _apiKey = apiKey,
        _baseUrl = baseUrl ?? Uri.parse('https://api.openai.com');

  static const int maxBytes = 25 * 1024 * 1024;

  final HttpTransport _transport;
  final String _apiKey;
  final Uri _baseUrl;
  final String model;

  @override
  ProviderId get id => const ProviderId('openai-transcribe');

  @override
  String get displayName => 'OpenAI Whisper';

  @override
  ProviderCapabilities get capabilities => const ProviderCapabilities(
        acceptsAudio: true,
        acceptsText: false,
        nativeJsonSchema: false,
        wordTimestamps: true,
        maxRequestBytes: maxBytes,
      );

  Map<String, String> get _headers => {
        'authorization': 'Bearer $_apiKey',
        'accept': 'application/json',
      };

  @override
  Future<ConnectionResult> test() =>
      openAiStyleTest(_transport, _baseUrl, _headers, displayName, model);

  @override
  Future<List<TranscriptSegment>> transcribe(TranscribeRequest request) async {
    if (request.audio.length > maxBytes) {
      throw ProviderException(
        displayName,
        0,
        'Chunk is ${(request.audio.length / 1048576).toStringAsFixed(1)} MB; the limit is '
        '25 MB. The chunker should have split this — check maxRequestBytes is being read '
        'from capabilities.',
      );
    }

    final form = MultipartBody()
      ..addField('model', model)
      ..addField('response_format', 'verbose_json')
      ..addField('timestamp_granularities[]', 'segment');
    if (request.languageHint != null) {
      form.addField('language', request.languageHint!);
    }
    // Carries proper nouns across the chunk seam so spelling stays consistent.
    if (request.primingPrompt != null && request.primingPrompt!.isNotEmpty) {
      form.addField('prompt', request.primingPrompt!);
    }
    form.addFile('file', 'chunk.wav', request.audio, request.mimeType);

    final reply = await _transport.send(HttpCall(
      method: 'POST',
      url: _baseUrl.resolve('/v1/audio/transcriptions'),
      headers: _headers,
      contentType: form.contentType,
      bodyBytes: form.finish(),
      timeout: const Duration(minutes: 10),
    ));

    if (!reply.ok) {
      throw ProviderException(displayName, reply.statusCode,
          providerErrorMessage(reply.json, reply.body));
    }

    final segments = reply.json?['segments'];
    if (segments is! List) {
      // `response_format=text` or an older deployment: one undifferentiated blob.
      final text = reply.json?['text']?.toString() ?? '';
      return [
        TranscriptSegment(
          startMs: request.offsetMs,
          endMs: request.offsetMs,
          text: text,
        )
      ];
    }

    return segments.whereType<Map<String, dynamic>>().map((s) {
      final start = ((s['start'] as num?) ?? 0) * 1000;
      final end = ((s['end'] as num?) ?? 0) * 1000;
      return TranscriptSegment(
        startMs: start.round() + request.offsetMs,
        endMs: end.round() + request.offsetMs,
        text: (s['text'] ?? '').toString().trim(),
      );
    }).toList();
  }
}

/// `GET /v1/models` — the shape every OpenAI-compatible server implements, including
/// Ollama and LM Studio, which is why this is shared rather than duplicated.
Future<ConnectionResult> openAiStyleTest(
  HttpTransport transport,
  Uri baseUrl,
  Map<String, String> headers,
  String providerName,
  String? expectedModel, {
  bool isLocalEndpoint = false,
}) async {
  final started = DateTime.now();
  try {
    final reply = await transport.send(HttpCall(
      method: 'GET',
      url: baseUrl.resolve('/v1/models'),
      headers: headers,
      timeout: Duration(seconds: isLocalEndpoint ? 30 : 15),
    ));

    if (!reply.ok) {
      return describeHttpFailure(reply,
          providerName: providerName, isLocalEndpoint: isLocalEndpoint);
    }

    final data = reply.json?['data'];
    final models = data is List
        ? data
            .whereType<Map<String, dynamic>>()
            .map((m) => (m['id'] as Object?).toString())
            .toList()
        : <String>[];
    final elapsed = DateTime.now().difference(started);

    if (models.isEmpty && isLocalEndpoint) {
      return ConnectionResult.failure(
        summary: 'Server is running but has no models loaded',
        remedy: 'Pull or load a model first, then test again.',
      );
    }

    if (expectedModel != null &&
        models.isNotEmpty &&
        !models.any(
            (m) => m == expectedModel || m.startsWith('$expectedModel:'))) {
      return ConnectionResult.failure(
        summary: 'Connected, but $expectedModel is not available',
        detail: 'Available: ${models.take(6).join(', ')}',
        remedy: 'Pick one of the listed models in settings.',
      );
    }

    return ConnectionResult.success(
      summary:
          'Connected · ${models.length} model${models.length == 1 ? '' : 's'} · '
          '${elapsed.inMilliseconds} ms',
      models: models,
      latency: elapsed,
    );
  } on TransportException catch (e) {
    return describeTransportFailure(e,
        providerName: providerName, isLocalEndpoint: isLocalEndpoint);
  }
}
