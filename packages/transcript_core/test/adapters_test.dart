import 'dart:convert';

import 'package:test/test.dart';
import 'package:transcript_core/transcript_core.dart';

void main() {
  const structureRequest = StructureRequest(
    systemPrompt: 'SYSTEM',
    userContent: '<transcript>hello</transcript>',
    schema: {
      'type': 'object',
      'additionalProperties': false,
      'required': ['x'],
      'properties': {
        'x': {
          'type': ['string', 'null']
        }
      },
    },
  );

  group('Anthropic', () {
    test('sends the schema as output_config.format with adaptive thinking',
        () async {
      final transport = RecordingTransport.single(
        HttpReply(
            200,
            jsonEncode({
              'content': [
                {'type': 'text', 'text': '{"x":"ok"}'}
              ],
              'usage': {'input_tokens': 10, 'output_tokens': 4},
              'model': 'claude-opus-5',
              'stop_reason': 'end_turn',
            })),
      );

      final provider = AnthropicStructuringProvider(
        transport: transport,
        apiKey: 'sk-test',
      );
      final response = await provider.structure(structureRequest);

      final body = transport.lastCall.jsonBodyMap;
      expect(transport.lastCall.url.path, '/v1/messages');
      expect(transport.lastCall.headers['x-api-key'], 'sk-test');
      expect(transport.lastCall.headers['anthropic-version'], isNotNull);
      expect(body['model'], 'claude-opus-5');
      expect((body['thinking'] as Map)['type'], 'adaptive',
          reason: 'budget_tokens was removed on this model family');
      expect(body.containsKey('temperature'), isFalse,
          reason:
              'sampling parameters are rejected alongside adaptive thinking');

      final format = (body['output_config'] as Map)['format'] as Map;
      expect(format['type'], 'json_schema');
      expect(response.rawText, '{"x":"ok"}');
      expect(response.inputTokens, 10);
    });

    test('marks the stable system prompt as cacheable', () async {
      final transport = RecordingTransport.single(HttpReply(
          200, jsonEncode({'content': <Object>[], 'stop_reason': 'end_turn'})));
      await AnthropicStructuringProvider(transport: transport, apiKey: 'k')
          .structure(structureRequest);

      final system =
          (transport.lastCall.jsonBodyMap['system'] as List).first as Map;
      expect(system['cache_control'], equals({'type': 'ephemeral'}),
          reason:
              'the system prompt and schema are identical across recordings');
    });

    test('a refusal arrives as HTTP 200 and must not be parsed as content',
        () async {
      final transport = RecordingTransport.single(HttpReply(
        200,
        jsonEncode({
          'stop_reason': 'refusal',
          'stop_details': {'type': 'refusal', 'category': 'cyber'},
          'content': <Object>[],
        }),
      ));

      await expectLater(
        AnthropicStructuringProvider(transport: transport, apiKey: 'k')
            .structure(structureRequest),
        throwsA(isA<ProviderException>()
            .having((e) => e.message, 'message', contains('declined'))),
      );
    });

    test('connection test reports the model list', () async {
      final transport = RecordingTransport.single(HttpReply(
        200,
        jsonEncode({
          'data': [
            {'id': 'claude-opus-5'},
            {'id': 'claude-sonnet-5'},
          ]
        }),
      ));

      final result =
          await AnthropicStructuringProvider(transport: transport, apiKey: 'k')
              .test();
      expect(result.ok, isTrue);
      expect(result.models, contains('claude-sonnet-5'));
    });

    test('a key without access to the configured model fails usefully',
        () async {
      final transport = RecordingTransport.single(HttpReply(
        200,
        jsonEncode({
          'data': [
            {'id': 'claude-haiku-4-5'}
          ]
        }),
      ));

      final result = await AnthropicStructuringProvider(
        transport: transport,
        apiKey: 'k',
        model: 'claude-opus-5',
      ).test();

      expect(result.ok, isFalse);
      expect(result.summary, contains('not available'));
      expect(result.remedy, isNotNull);
    });
  });

  group('OpenAI', () {
    test('sends strict json_schema and never a raw \$ref', () async {
      final transport = RecordingTransport.single(HttpReply(
        200,
        jsonEncode({
          'choices': [
            {
              'message': {'content': '{"x":null}'}
            }
          ],
          'usage': {'prompt_tokens': 8, 'completion_tokens': 2},
        }),
      ));

      await OpenAiStructuringProvider(transport: transport, apiKey: 'sk-x')
          .structure(structureRequest);

      final schema = ((transport.lastCall.jsonBodyMap['response_format']
          as Map)['json_schema']) as Map;
      expect(schema['strict'], isTrue);
      expect(jsonEncode(schema['schema']), isNot(contains(r'$ref')));
      expect(transport.lastCall.headers['authorization'], 'Bearer sk-x');
    });

    test('transcription posts multipart with the priming prompt attached',
        () async {
      final transport = RecordingTransport.single(HttpReply(
        200,
        jsonEncode({
          'segments': [
            {'start': 0.0, 'end': 2.5, 'text': ' Hello there.'},
            {'start': 2.5, 'end': 5.0, 'text': ' Second bit.'},
          ]
        }),
      ));

      final segments = await OpenAiTranscriptionProvider(
        transport: transport,
        apiKey: 'sk-x',
      ).transcribe(const TranscribeRequest(
        audio: [1, 2, 3],
        mimeType: 'audio/wav',
        offsetMs: 45000,
        primingPrompt: 'Kubernetes, Priya, OIDC',
      ));

      final body = utf8.decode(transport.lastCall.bodyBytes!);
      expect(transport.lastCall.url.path, '/v1/audio/transcriptions');
      expect(transport.lastCall.contentType, contains('multipart/form-data'));
      expect(body, contains('name="prompt"'));
      expect(body, contains('Kubernetes, Priya, OIDC'),
          reason:
              'the priming prompt is what keeps proper nouns stable across seams');
      expect(body, contains('name="file"; filename="chunk.wav"'));

      // Offsets must be absolute in the recording, not relative to the chunk.
      expect(segments.first.startMs, 45000);
      expect(segments.last.endMs, 50000);
      expect(segments.first.text, 'Hello there.');
    });

    test('an oversized chunk is refused before it hits the network', () async {
      final transport = RecordingTransport(const []);
      await expectLater(
        OpenAiTranscriptionProvider(transport: transport, apiKey: 'k')
            .transcribe(
          TranscribeRequest(
            audio: List.filled(26 * 1024 * 1024, 0),
            mimeType: 'audio/wav',
          ),
        ),
        throwsA(isA<ProviderException>()),
      );
      expect(transport.calls, isEmpty,
          reason: 'no point uploading 26 MB to be rejected');
    });
  });

  group('Gemini', () {
    test('renders the schema into the OpenAPI subset', () async {
      final transport = RecordingTransport.single(HttpReply(
        200,
        jsonEncode({
          'candidates': [
            {
              'content': {
                'parts': [
                  {'text': '{"x":"ok"}'}
                ]
              }
            }
          ],
        }),
      ));

      await GeminiStructuringProvider(transport: transport, apiKey: 'g')
          .structure(structureRequest);

      final config = transport.lastCall.jsonBodyMap['generationConfig'] as Map;
      final schema = config['responseSchema'] as Map<String, dynamic>;
      expect(config['responseMimeType'], 'application/json');
      expect(schema.containsKey('additionalProperties'), isFalse);

      final x = (schema['properties'] as Map)['x'] as Map;
      expect(x['type'], 'string');
      expect(x['nullable'], isTrue,
          reason: 'the OpenAPI subset has no ["string","null"] union');
    });

    test('audio is sent inline as base64', () async {
      final transport = RecordingTransport.single(HttpReply(
        200,
        jsonEncode({
          'candidates': [
            {
              'content': {
                'parts': [
                  {
                    'text':
                        '{"segments":[{"startMs":0,"endMs":900,"text":"Hi"}]}'
                  }
                ]
              }
            }
          ],
        }),
      ));

      final segments =
          await GeminiTranscriptionProvider(transport: transport, apiKey: 'g')
              .transcribe(const TranscribeRequest(
        audio: [72, 105],
        mimeType: 'audio/wav',
        offsetMs: 1000,
      ));

      final parts = ((transport.lastCall.jsonBodyMap['contents'] as List).first
          as Map)['parts'] as List;
      final inline = (parts.last as Map)['inlineData'] as Map;
      expect(inline['data'], base64Encode([72, 105]));
      expect(segments.single.startMs, 1000, reason: 'offset applied');
    });
  });

  group('local models', () {
    test('discovers the context window from Ollama and reports it', () async {
      final transport = RecordingTransport([
        HttpReply(
            200,
            jsonEncode({
              'data': [
                {'id': 'llama3.1:8b'}
              ]
            })),
        HttpReply(
            200,
            jsonEncode({
              'model_info': {'llama.context_length': 8192},
            })),
      ]);

      final provider = LocalStructuringProvider(
        transport: transport,
        baseUrl: Uri.parse('http://192.168.1.50:11434'),
        model: 'llama3.1:8b',
      );

      final result = await provider.test();
      expect(result.ok, isTrue);
      expect(result.summary, contains('8k context'));
      expect(provider.capabilities.contextWindowTokens, 8192);
      expect(result.detail, contains('minutes'),
          reason: 'the user needs to know how much recording fits in one pass');
    });

    test('an unknown context window stays conservative rather than guessing',
        () async {
      final transport = RecordingTransport([
        HttpReply(
            200,
            jsonEncode({
              'data': [
                {'id': 'local-model'}
              ]
            })),
      ]);

      final provider = LocalStructuringProvider(
        transport: transport,
        baseUrl: Uri.parse('http://192.168.1.50:1234'),
        model: 'local-model',
        flavor: LocalFlavor.lmStudio,
      );

      final result = await provider.test();
      expect(result.ok, isTrue);
      expect(provider.capabilities.contextWindowTokens, 0,
          reason: 'zero means unknown, which forces the map/reduce path');
    });

    test('a refused connection explains the three usual local causes',
        () async {
      final transport = RecordingTransport([
        const TransportException(
            TransportFailure.refused, 'Connection refused'),
      ]);

      final result = await LocalStructuringProvider(
        transport: transport,
        baseUrl: Uri.parse('http://192.168.1.50:11434'),
        model: 'llama3.1:8b',
      ).test();

      expect(result.ok, isFalse);
      expect(result.remedy, contains('OLLAMA_HOST=0.0.0.0'));
      expect(result.remedy, contains('Local Network'),
          reason:
              'on iOS this is indistinguishable from the server being down');
    });

    test('a server with no models loaded says so specifically', () async {
      final transport = RecordingTransport([
        HttpReply(200, jsonEncode({'data': <Object>[]}))
      ]);

      final result = await LocalStructuringProvider(
        transport: transport,
        baseUrl: Uri.parse('http://192.168.1.50:11434'),
        model: 'llama3.1:8b',
      ).test();

      expect(result.ok, isFalse);
      expect(result.summary, contains('no models loaded'));
    });

    test('local requests get a generous timeout for a cold model', () async {
      final transport = RecordingTransport.single(HttpReply(
        200,
        jsonEncode({
          'choices': [
            {
              'message': {'content': '{"x":null}'}
            }
          ]
        }),
      ));

      await LocalStructuringProvider(
        transport: transport,
        baseUrl: Uri.parse('http://10.0.2.2:11434'),
        model: 'llama3.1:8b',
      ).structure(structureRequest);

      expect(transport.lastCall.timeout,
          greaterThanOrEqualTo(const Duration(minutes: 5)));
    });
  });

  group('failure diagnostics', () {
    test('401 on a cloud provider blames the key, not the network', () {
      final result = describeHttpFailure(
        HttpReply(
            401,
            jsonEncode({
              'error': {'message': 'invalid x-api-key'}
            })),
        providerName: 'Claude',
      );
      expect(result.ok, isFalse);
      expect(result.detail, contains('invalid x-api-key'));
      expect(result.remedy, contains('revoked'));
    });

    test('404 on a local endpoint names the paths each server serves', () {
      final result = describeHttpFailure(
        HttpReply(404, 'not found'),
        providerName: 'Ollama',
        isLocalEndpoint: true,
      );
      expect(result.remedy, contains('/v1'));
    });

    test('an HTML error page from a proxy is surfaced, not swallowed', () {
      final result = describeHttpFailure(
        HttpReply(502, '<html><body>Bad Gateway</body></html>'),
        providerName: 'Ollama',
        isLocalEndpoint: true,
      );
      expect(result.detail, contains('Bad Gateway'));
    });

    test('a timeout on a local endpoint mentions cold model load', () {
      final result = describeTransportFailure(
        const TransportException(
            TransportFailure.timeout, 'no response in 600s'),
        providerName: 'Ollama',
        isLocalEndpoint: true,
      );
      expect(result.remedy, contains('cold local model'));
    });

    test('diagnostics never echo the API key', () {
      final result = describeHttpFailure(
        HttpReply(
            401,
            jsonEncode({
              'error': {'message': 'bad key'}
            })),
        providerName: 'OpenAI',
      );
      final rendered = '${result.summary} ${result.detail} ${result.remedy}';
      expect(rendered, isNot(contains('sk-')));
    });
  });
}
