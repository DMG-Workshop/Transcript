import '../../schema/dialects.dart';
import '../capabilities.dart';
import '../connection.dart';
import '../errors.dart';
import '../http_transport.dart';
import '../provider.dart';

/// Anthropic Claude — structuring only.
///
/// The Messages API accepts text, images and PDFs; it has no audio input. That is the
/// fact that forces this app's two-slot architecture, so this class deliberately does not
/// implement [TranscriptionProvider] and never will.
class AnthropicStructuringProvider extends StructuringProvider {
  AnthropicStructuringProvider({
    required HttpTransport transport,
    required String apiKey,
    this.model = defaultModel,
    Uri? baseUrl,
  })  : _transport = transport,
        _apiKey = apiKey,
        _baseUrl = baseUrl ?? Uri.parse('https://api.anthropic.com');

  static const String defaultModel = 'claude-opus-5';
  static const String apiVersion = '2023-06-01';

  /// Server-side refusal fallbacks: if a safety classifier declines the request, the API
  /// routes to a suitable alternative model rather than returning an unusable response.
  /// Structuring a recording is benign, but transcripts are user content we never see,
  /// and a hard failure on a two-hour meeting is a bad outcome for the user.
  static const String fallbackBeta = 'server-side-fallback-2026-07-01';

  final HttpTransport _transport;
  final String _apiKey;
  final Uri _baseUrl;
  final String model;

  @override
  ProviderId get id => const ProviderId('anthropic');

  @override
  String get displayName => 'Claude';

  @override
  ProviderCapabilities get capabilities => const ProviderCapabilities(
        acceptsAudio: false,
        acceptsText: true,
        nativeJsonSchema: true,
        streaming: true,
        contextWindowTokens: 1000000,
        maxOutputTokens: 128000,
      );

  Map<String, String> get _headers => {
        'x-api-key': _apiKey,
        'anthropic-version': apiVersion,
        'anthropic-beta': fallbackBeta,
        'accept': 'application/json',
      };

  @override
  Future<ConnectionResult> test() async {
    final started = DateTime.now();
    try {
      final reply = await _transport.send(HttpCall(
        method: 'GET',
        url: _baseUrl.resolve('/v1/models'),
        headers: _headers,
        timeout: const Duration(seconds: 15),
      ));

      if (!reply.ok) {
        return describeHttpFailure(reply, providerName: displayName);
      }

      final data = reply.json?['data'];
      final models = data is List
          ? data
              .whereType<Map<String, dynamic>>()
              .map((m) => (m['id'] as Object?).toString())
              .toList()
          : <String>[];
      final elapsed = DateTime.now().difference(started);

      if (models.isNotEmpty && !models.contains(model)) {
        return ConnectionResult.failure(
          summary: 'Connected, but $model is not available to this key',
          detail: 'Available: ${models.take(6).join(', ')}',
          remedy: 'Pick one of the listed models in settings.',
        );
      }

      return ConnectionResult.success(
        summary: 'Connected · $model · ${elapsed.inMilliseconds} ms',
        models: models,
        latency: elapsed,
      );
    } on TransportException catch (e) {
      return describeTransportFailure(e, providerName: displayName);
    }
  }

  @override
  Future<StructureResponse> structure(StructureRequest request) async {
    final reply = await _transport.send(HttpCall(
      method: 'POST',
      url: _baseUrl.resolve('/v1/messages'),
      headers: _headers,
      timeout: const Duration(minutes: 5),
      jsonBody: {
        'model': model,
        'max_tokens': request.maxOutputTokens,
        // The system prompt and the schema are byte-stable across every recording, so
        // they sit behind a cache breakpoint and the volatile transcript follows.
        'system': [
          {
            'type': 'text',
            'text': request.systemPrompt,
            'cache_control': {'type': 'ephemeral'},
          }
        ],
        'messages': [
          for (final turn in request.priorTurns)
            {'role': turn.role, 'content': turn.content},
          {'role': 'user', 'content': request.userContent},
        ],
        // Adaptive thinking is on by default for this model family; `budget_tokens` was
        // removed and would be rejected.
        'thinking': {'type': 'adaptive'},
        'output_config': {
          'effort': 'high',
          'format': {
            'type': 'json_schema',
            'schema': renderSchema(request.schema, SchemaDialect.plain),
          },
        },
        'fallbacks': 'default',
      },
    ));

    if (!reply.ok) {
      throw ProviderException(
        displayName,
        reply.statusCode,
        providerErrorMessage(reply.json, reply.body),
      );
    }

    final body = reply.json ?? const {};

    // A refusal arrives as HTTP 200 with stop_reason "refusal" — always check before
    // reading content, or you parse an empty block as malformed JSON.
    if (body['stop_reason'] == 'refusal') {
      final details = body['stop_details'];
      final category =
          details is Map<String, dynamic> ? details['category'] : null;
      throw ProviderException(
        displayName,
        200,
        'The model declined to process this transcript'
        '${category == null ? '' : ' ($category)'}.',
      );
    }

    final content = body['content'];
    final text = content is List
        ? content
            .whereType<Map<String, dynamic>>()
            .where((b) => b['type'] == 'text')
            .map((b) => (b['text'] as Object?).toString())
            .join()
        : '';

    final usage = (body['usage'] as Map?)?.cast<String, dynamic>();
    return StructureResponse(
      rawText: text,
      inputTokens: usage?['input_tokens'] as int?,
      outputTokens: usage?['output_tokens'] as int?,
      model: body['model'] as String?,
    );
  }
}
