import '../../schema/dialects.dart';
import '../capabilities.dart';
import '../connection.dart';
import '../errors.dart';
import '../http_transport.dart';
import '../provider.dart';
import 'openai.dart';

/// Which local server is on the other end. Both speak the OpenAI chat API; they differ in
/// their native management endpoints, which is where the context window lives.
enum LocalFlavor {
  ollama(defaultPort: 11434, label: 'Ollama'),
  lmStudio(defaultPort: 1234, label: 'LM Studio');

  const LocalFlavor({required this.defaultPort, required this.label});

  final int defaultPort;
  final String label;
}

/// A model running on the user's own machine.
///
/// The interesting problem here is not the protocol — it is that the context window is
/// small and unknown. A 7B model served at 4096 tokens cannot hold a one-hour transcript,
/// and the failure mode is silent truncation. So this adapter discovers the real context
/// length at connection-test time and reports it through [capabilities], which is what the
/// pipeline uses to decide between a single pass and map/reduce.
class LocalStructuringProvider extends StructuringProvider {
  LocalStructuringProvider({
    required HttpTransport transport,
    required this.baseUrl,
    required this.model,
    this.flavor = LocalFlavor.ollama,
    this.apiKey,
  }) : _transport = transport;

  /// Local models are slow to first token when cold — loading a 7B from disk can take
  /// most of a minute. A cloud-scale timeout here produces spurious failures.
  static const Duration localTimeout = Duration(minutes: 10);

  final HttpTransport _transport;
  final Uri baseUrl;
  final String model;
  final LocalFlavor flavor;

  /// Some users put a reverse proxy with auth in front of their model server.
  final String? apiKey;

  int _discoveredContext = 0;

  @override
  ProviderId get id => ProviderId('local:${flavor.name}:${baseUrl.host}');

  @override
  String get displayName => '${flavor.label} (${baseUrl.host})';

  @override
  bool get isLocalEndpoint => true;

  @override
  ProviderCapabilities get capabilities => ProviderCapabilities(
        acceptsAudio: false,
        acceptsText: true,
        nativeJsonSchema: true,
        requiresApiKey: false,
        runsOnDevice: false, // on the user's network, not on the phone
        contextWindowTokens: _discoveredContext,
        maxOutputTokens: 4096,
      );

  Map<String, String> get _headers => {
        'accept': 'application/json',
        if (apiKey != null && apiKey!.isNotEmpty)
          'authorization': 'Bearer $apiKey',
      };

  @override
  Future<ConnectionResult> test() async {
    final result = await openAiStyleTest(
      _transport,
      baseUrl,
      _headers,
      flavor.label,
      model,
      isLocalEndpoint: true,
    );
    if (!result.ok) return result;

    final context = await _discoverContextWindow();
    if (context == null) {
      return ConnectionResult.success(
        summary: '${result.summary} · context window unknown',
        models: result.models,
        latency: result.latency,
        detail:
            'Long recordings will be processed in sections, conservatively.',
      );
    }

    _discoveredContext = context;
    final minutes = _approxTranscriptMinutes(context);
    return ConnectionResult.success(
      summary: '${result.summary} · ${_formatTokens(context)} context',
      models: result.models,
      latency: result.latency,
      detail:
          'Fits roughly $minutes minutes of speech in one pass; anything longer is '
          'processed in sections and merged.',
    );
  }

  /// Ollama exposes the real context length through `/api/show`. LM Studio does not
  /// expose it over HTTP at all, so callers get null and the pipeline stays conservative.
  Future<int?> _discoverContextWindow() async {
    if (flavor != LocalFlavor.ollama) return null;
    try {
      final reply = await _transport.send(HttpCall(
        method: 'POST',
        url: baseUrl.resolve('/api/show'),
        headers: _headers,
        jsonBody: {'model': model},
        timeout: const Duration(seconds: 30),
      ));
      if (!reply.ok) return null;

      final info = reply.json?['model_info'];
      if (info is! Map<String, dynamic>) return null;
      for (final entry in info.entries) {
        if (entry.key.endsWith('.context_length') && entry.value is int) {
          return entry.value as int;
        }
      }
      return null;
    } on TransportException {
      return null; // the chat endpoint already tested fine; this is a bonus
    }
  }

  @override
  Future<StructureResponse> structure(StructureRequest request) async {
    final reply = await _transport.send(HttpCall(
      method: 'POST',
      url: baseUrl.resolve('/v1/chat/completions'),
      headers: _headers,
      timeout: localTimeout,
      jsonBody: {
        'model': model,
        'max_tokens': request.maxOutputTokens,
        'stream': false,
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
      model: body['model']?.toString() ?? model,
    );
  }

  /// Very rough: ~13k tokens per hour of speech, minus prompt and schema overhead.
  static int _approxTranscriptMinutes(int contextTokens) {
    const promptOverhead = 3500; // system prompt + rendered schema
    const outputReserve = 4000;
    final usable = contextTokens - promptOverhead - outputReserve;
    if (usable <= 0) return 0;
    return (usable / 13000 * 60).round();
  }

  static String _formatTokens(int tokens) =>
      tokens >= 1000 ? '${(tokens / 1000).round()}k' : '$tokens';
}

/// Candidate addresses to probe when the user asks the app to find their model server.
/// mDNS is unreliable on mobile, so discovery is a scan of the obvious ports on the
/// device's own subnet plus the emulator loopback aliases.
List<Uri> localCandidates(String subnetPrefix) => [
      for (final flavor in LocalFlavor.values) ...[
        Uri.parse('http://$subnetPrefix.1:${flavor.defaultPort}'),
        // Android emulator alias for the host machine.
        Uri.parse('http://10.0.2.2:${flavor.defaultPort}'),
      ],
    ];
