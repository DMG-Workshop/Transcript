import 'dart:convert';

import '../../schema/dialects.dart';
import '../capabilities.dart';
import '../connection.dart';
import '../errors.dart';
import '../http_transport.dart';
import '../provider.dart';

/// Google Gemini — the only provider that can do both stages, because it takes audio
/// natively. Still exposed as two classes so the user can pair it with anything else.
class GeminiStructuringProvider extends StructuringProvider {
  GeminiStructuringProvider({
    required HttpTransport transport,
    required String apiKey,
    this.model = 'gemini-2.0-flash',
    Uri? baseUrl,
  })  : _transport = transport,
        _apiKey = apiKey,
        _baseUrl =
            baseUrl ?? Uri.parse('https://generativelanguage.googleapis.com');

  final HttpTransport _transport;
  final String _apiKey;
  final Uri _baseUrl;
  final String model;

  @override
  ProviderId get id => const ProviderId('gemini');

  @override
  String get displayName => 'Gemini';

  @override
  ProviderCapabilities get capabilities => const ProviderCapabilities(
        acceptsAudio: false, // structuring half
        acceptsText: true,
        nativeJsonSchema: true,
        streaming: true,
        contextWindowTokens: 1000000,
        maxOutputTokens: 8192,
      );

  @override
  Future<ConnectionResult> test() =>
      _geminiTest(_transport, _baseUrl, _apiKey, displayName, model);

  @override
  Future<StructureResponse> structure(StructureRequest request) async {
    final reply = await _transport.send(HttpCall(
      method: 'POST',
      url: _baseUrl.resolve('/v1beta/models/$model:generateContent'),
      headers: {'x-goog-api-key': _apiKey, 'accept': 'application/json'},
      timeout: const Duration(minutes: 5),
      jsonBody: {
        'systemInstruction': {
          'parts': [
            {'text': request.systemPrompt}
          ]
        },
        'contents': [
          for (final turn in request.priorTurns)
            {
              'role': turn.role == 'assistant' ? 'model' : 'user',
              'parts': [
                {'text': turn.content}
              ],
            },
          {
            'role': 'user',
            'parts': [
              {'text': request.userContent}
            ],
          },
        ],
        'generationConfig': {
          'responseMimeType': 'application/json',
          // Gemini takes an OpenAPI 3.0 subset: no $ref, no additionalProperties, and
          // nullability as `nullable: true` rather than a type union. The dialect
          // renderer handles all three.
          'responseSchema': renderSchema(request.schema, SchemaDialect.gemini),
          'maxOutputTokens': request.maxOutputTokens,
        },
      },
    ));

    if (!reply.ok) {
      throw ProviderException(displayName, reply.statusCode,
          providerErrorMessage(reply.json, reply.body));
    }

    final body = reply.json ?? const {};
    final candidates = body['candidates'];
    var text = '';
    if (candidates is List && candidates.isNotEmpty) {
      final content = (candidates.first as Map<String, dynamic>)['content'];
      final parts = content is Map ? content['parts'] : null;
      if (parts is List) {
        text = parts
            .whereType<Map<String, dynamic>>()
            .map((p) => p['text']?.toString() ?? '')
            .join();
      }
    }

    final usage = (body['usageMetadata'] as Map?)?.cast<String, dynamic>();
    return StructureResponse(
      rawText: text,
      inputTokens: usage?['promptTokenCount'] as int?,
      outputTokens: usage?['candidatesTokenCount'] as int?,
      model: model,
    );
  }
}

/// Gemini as a transcription provider. Audio is sent inline as base64, which is fine up
/// to roughly 20 MB of request; beyond that the Files API is required, so the chunker's
/// byte cap is set below the inline limit and the Files path stays out of Phase 1.
class GeminiTranscriptionProvider extends TranscriptionProvider {
  GeminiTranscriptionProvider({
    required HttpTransport transport,
    required String apiKey,
    this.model = 'gemini-2.0-flash',
    Uri? baseUrl,
  })  : _transport = transport,
        _apiKey = apiKey,
        _baseUrl =
            baseUrl ?? Uri.parse('https://generativelanguage.googleapis.com');

  /// Below Gemini's ~20 MB inline ceiling, with headroom for base64's 4/3 expansion.
  static const int maxBytes = 14 * 1024 * 1024;

  final HttpTransport _transport;
  final String _apiKey;
  final Uri _baseUrl;
  final String model;

  @override
  ProviderId get id => const ProviderId('gemini-transcribe');

  @override
  String get displayName => 'Gemini (audio)';

  @override
  ProviderCapabilities get capabilities => const ProviderCapabilities(
        acceptsAudio: true,
        acceptsText: false,
        nativeJsonSchema: true,
        maxRequestBytes: maxBytes,
      );

  @override
  Future<ConnectionResult> test() =>
      _geminiTest(_transport, _baseUrl, _apiKey, displayName, model);

  @override
  Future<List<TranscriptSegment>> transcribe(TranscribeRequest request) async {
    // Gemini has no transcription endpoint — it is a generative call with audio attached,
    // so the segment structure has to be asked for explicitly and validated like any
    // other model output.
    final instruction = StringBuffer()
      ..writeln('Transcribe this audio verbatim.')
      ..writeln(
          'Return JSON: {"segments":[{"startMs":int,"endMs":int,"text":string}]}.')
      ..writeln('Offsets are milliseconds from the start of THIS audio clip.')
      ..writeln(
          'Do not summarize, correct grammar, or omit filler. Transcribe only.');
    if (request.primingPrompt case final priming? when priming.isNotEmpty) {
      instruction.writeln(
          'Context from the preceding audio, for consistent spelling of names and '
          'technical terms: "$priming"');
    }

    final reply = await _transport.send(HttpCall(
      method: 'POST',
      url: _baseUrl.resolve('/v1beta/models/$model:generateContent'),
      headers: {'x-goog-api-key': _apiKey, 'accept': 'application/json'},
      timeout: const Duration(minutes: 10),
      jsonBody: {
        'contents': [
          {
            'role': 'user',
            'parts': [
              {'text': instruction.toString()},
              {
                'inlineData': {
                  'mimeType': request.mimeType,
                  'data': base64Encode(request.audio),
                }
              },
            ],
          }
        ],
        'generationConfig': {
          'responseMimeType': 'application/json',
          'responseSchema': renderSchema(_segmentsSchema, SchemaDialect.gemini),
        },
      },
    ));

    if (!reply.ok) {
      throw ProviderException(displayName, reply.statusCode,
          providerErrorMessage(reply.json, reply.body));
    }

    final candidates = reply.json?['candidates'];
    var text = '';
    if (candidates is List && candidates.isNotEmpty) {
      final content = (candidates.first as Map<String, dynamic>)['content'];
      final parts = content is Map ? content['parts'] : null;
      if (parts is List) {
        text = parts
            .whereType<Map<String, dynamic>>()
            .map((p) => p['text']?.toString() ?? '')
            .join();
      }
    }

    final decoded = jsonDecode(text);
    final segments = decoded is Map ? decoded['segments'] : null;
    if (segments is! List) {
      throw ProviderException(
          displayName, 200, 'Response contained no segments array.');
    }

    return segments.whereType<Map<String, dynamic>>().map((s) {
      final start = (s['startMs'] as num?)?.round() ?? 0;
      final end = (s['endMs'] as num?)?.round() ?? start;
      return TranscriptSegment(
        startMs: start + request.offsetMs,
        endMs: end + request.offsetMs,
        text: (s['text'] ?? '').toString().trim(),
      );
    }).toList();
  }
}

const Map<String, dynamic> _segmentsSchema = {
  'type': 'object',
  'additionalProperties': false,
  'required': ['segments'],
  'properties': {
    'segments': {
      'type': 'array',
      'items': {
        'type': 'object',
        'additionalProperties': false,
        'required': ['startMs', 'endMs', 'text'],
        'properties': {
          'startMs': {'type': 'integer'},
          'endMs': {'type': 'integer'},
          'text': {'type': 'string'},
        },
      },
    },
  },
};

Future<ConnectionResult> _geminiTest(
  HttpTransport transport,
  Uri baseUrl,
  String apiKey,
  String providerName,
  String expectedModel,
) async {
  final started = DateTime.now();
  try {
    final reply = await transport.send(HttpCall(
      method: 'GET',
      url: baseUrl.resolve('/v1beta/models'),
      headers: {'x-goog-api-key': apiKey, 'accept': 'application/json'},
      timeout: const Duration(seconds: 15),
    ));

    if (!reply.ok) {
      return describeHttpFailure(reply, providerName: providerName);
    }

    final list = reply.json?['models'];
    // Gemini returns fully-qualified names: "models/gemini-2.0-flash".
    final models = list is List
        ? list
            .whereType<Map<String, dynamic>>()
            .map((m) =>
                (m['name'] as Object?).toString().replaceFirst('models/', ''))
            .toList()
        : <String>[];
    final elapsed = DateTime.now().difference(started);

    if (models.isNotEmpty && !models.contains(expectedModel)) {
      return ConnectionResult.failure(
        summary: 'Connected, but $expectedModel is not available to this key',
        detail: 'Available: ${models.take(6).join(', ')}',
        remedy: 'Pick one of the listed models in settings.',
      );
    }

    return ConnectionResult.success(
      summary: 'Connected · $expectedModel · ${elapsed.inMilliseconds} ms',
      models: models,
      latency: elapsed,
    );
  } on TransportException catch (e) {
    return describeTransportFailure(e, providerName: providerName);
  }
}
