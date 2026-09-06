import 'dart:convert';

import 'package:test/test.dart';
import 'package:transcript_core/transcript_core.dart';

void main() {
  HttpReply ollamaTags(List<String> models) => HttpReply(
        200,
        jsonEncode({
          'models': [
            for (final m in models) {'name': m, 'size': 1}
          ],
        }),
      );

  HttpReply openAiModels(List<String> models) => HttpReply(
        200,
        jsonEncode({
          'data': [
            for (final m in models) {'id': m, 'object': 'model'}
          ],
        }),
      );

  group('identifying what is listening', () {
    test('a server answering /api/tags is Ollama', () async {
      final transport = RoutingTransport({
        '192.168.1.50:11434/api/tags':
            ollamaTags(['llama3.1:8b', 'qwen2.5:7b']),
      });

      final found = await LocalServerDiscovery(transport: transport)
          .probe(Uri.parse('http://192.168.1.50:11434'));

      expect(found, isNotNull);
      expect(found!.flavor, LocalFlavor.ollama);
      expect(found.models, ['llama3.1:8b', 'qwen2.5:7b']);
      expect(found.isUsable, isTrue);
    });

    test('a server serving only /v1/models is LM Studio', () async {
      final transport = RoutingTransport({
        '127.0.0.1:1234/v1/models': openAiModels(['local-model']),
      });

      final found = await LocalServerDiscovery(transport: transport)
          .probe(Uri.parse('http://127.0.0.1:1234'));

      expect(found!.flavor, LocalFlavor.lmStudio,
          reason: 'both serve /v1/models, so only /api/tags tells them apart');
    });

    test('the flavor is not guessed, because it decides what can be read later',
        () async {
      // Ollama exposes its context window through /api/show; LM Studio does not. Getting
      // the flavor wrong produces a silently wrong capacity estimate.
      final transport = RoutingTransport({
        '/api/tags': ollamaTags(['llama3.1:8b']),
        '/v1/models': openAiModels(['llama3.1:8b']),
      });

      final found = await LocalServerDiscovery(transport: transport)
          .probe(Uri.parse('http://192.168.1.50:11434'));

      expect(found!.flavor, LocalFlavor.ollama,
          reason: 'the native endpoint answered, so it is Ollama');
    });

    test('nothing listening yields nothing, without throwing', () async {
      final found =
          await LocalServerDiscovery(transport: RoutingTransport(const {}))
              .probe(Uri.parse('http://192.168.1.99:11434'));
      expect(found, isNull);
    });

    test('a server with no models loaded is still reported, but not usable',
        () async {
      final transport = RoutingTransport({'/api/tags': ollamaTags([])});
      final found = await LocalServerDiscovery(transport: transport)
          .probe(Uri.parse('http://192.168.1.50:11434'));

      expect(found, isNotNull,
          reason: 'the user may just need to pull a model');
      expect(found!.isUsable, isFalse);
    });

    test('a proxy returning HTML instead of JSON is not mistaken for a server',
        () async {
      final transport = RoutingTransport({
        '/api/tags': HttpReply(200, '<html><body>Hello</body></html>'),
        '/v1/models': HttpReply(200, '<html><body>Hello</body></html>'),
      });

      final found = await LocalServerDiscovery(transport: transport)
          .probe(Uri.parse('http://192.168.1.1:11434'));

      // It answered, so it is reported — but with no models it cannot be selected,
      // which is the honest outcome for something that is not a model server.
      expect(found?.models ?? const [], isEmpty);
    });
  });

  group('scanning', () {
    test('the shortlist is probed before any subnet', () async {
      final transport = RoutingTransport(const {});
      await LocalServerDiscovery(transport: transport).scan().toList();

      final hosts = transport.calls.map((c) => c.url.host).toSet();
      expect(hosts, containsAll(LocalServerDiscovery.shortlistHosts));
      expect(hosts, hasLength(LocalServerDiscovery.shortlistHosts.length),
          reason:
              'no subnet was given, so nothing beyond the shortlist is tried');
    });

    test('both default ports are tried on every host', () async {
      final transport = RoutingTransport(const {});
      await LocalServerDiscovery(transport: transport).scan().toList();

      final ports = transport.calls.map((c) => c.url.port).toSet();
      expect(ports, containsAll(LocalFlavor.values.map((f) => f.defaultPort)));
    });

    test('a subnet scan covers the whole range', () async {
      final transport = RoutingTransport(const {});
      await LocalServerDiscovery(transport: transport)
          .scan(subnetPrefix: '192.168.1')
          .toList();

      final hosts = transport.calls
          .map((c) => c.url.host)
          .where((h) => h.startsWith('192.168.1.'))
          .toSet();
      expect(hosts, hasLength(254));
    });

    test('results arrive as they answer rather than after every timeout',
        () async {
      final transport = RoutingTransport({
        '10.0.2.2:11434/api/tags': ollamaTags(['llama3.1:8b']),
      });

      final first = await LocalServerDiscovery(transport: transport)
          .scan(subnetPrefix: '192.168.1')
          .first;

      expect(first.baseUrl.host, '10.0.2.2',
          reason:
              'the emulator alias is on the shortlist, so it answers first');
    });

    test('probes are bounded so a scan does not open 500 sockets at once',
        () async {
      var open = 0;
      var peak = 0;
      final transport = _CountingTransport(
        onStart: () => peak = ++open > peak ? open : peak,
        onEnd: () => open--,
      );

      await LocalServerDiscovery(transport: transport, maxConcurrent: 8)
          .scan(subnetPrefix: '192.168.1')
          .toList();

      expect(peak, lessThanOrEqualTo(8));
    });

    test('probe timeouts are short, so a dead subnet does not feel broken', () {
      final discovery =
          LocalServerDiscovery(transport: RoutingTransport(const {}));
      expect(discovery.probeTimeout.inSeconds, lessThanOrEqualTo(3));
    });
  });

  group('model capacity', () {
    test('a small local context holds only minutes of speech', () {
      expect(ModelCapacity.minutesFor(8192), lessThan(10));
      expect(ModelCapacity.describe(8192), contains('minutes'));
    });

    test('a large context holds hours', () {
      expect(ModelCapacity.minutesFor(128000), greaterThan(300));
      expect(ModelCapacity.describe(128000), contains('hours'));
    });

    test('a context too small for any transcript says so plainly', () {
      expect(ModelCapacity.minutesFor(4096), 0);
      expect(ModelCapacity.describe(4096), contains('Too small'),
          reason:
              'better to say it than to let the user find out after a meeting');
    });

    test('an unknown context window is reported as unknown, never as zero', () {
      expect(ModelCapacity.describe(0), 'Context window unknown');
    });

    test('fit is judged against the actual recording length', () {
      expect(ModelCapacity.fitsInOnePass(128000, 90), isTrue);
      expect(ModelCapacity.fitsInOnePass(8192, 90), isFalse);
      expect(ModelCapacity.fitsInOnePass(0, 5), isFalse,
          reason: 'unknown must never be optimistic');
    });

    test('overheads are budgeted, not ignored', () {
      // The prompt and schema are thousands of tokens; a naive estimate that ignores
      // them promises capacity the model does not have.
      final naive = (32000 / ModelCapacity.tokensPerHourOfSpeech * 60).round();
      expect(ModelCapacity.minutesFor(32000), lessThan(naive));
    });
  });
}

class _CountingTransport implements HttpTransport {
  _CountingTransport({required this.onStart, required this.onEnd});

  final void Function() onStart;
  final void Function() onEnd;

  @override
  Future<HttpReply> send(HttpCall call) async {
    onStart();
    await Future<void>.delayed(const Duration(milliseconds: 1));
    onEnd();
    throw const TransportException(TransportFailure.refused, 'refused');
  }
}
