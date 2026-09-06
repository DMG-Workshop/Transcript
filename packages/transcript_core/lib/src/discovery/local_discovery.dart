import 'dart:async';

import '../providers/adapters/local.dart';
import '../providers/http_transport.dart';

/// A model server answering on the user's network.
class DiscoveredServer {
  const DiscoveredServer({
    required this.baseUrl,
    required this.flavor,
    required this.models,
    required this.latency,
  });

  final Uri baseUrl;
  final LocalFlavor flavor;

  /// What it has loaded. A server with none is still worth reporting — the user may
  /// simply need to pull a model — but it cannot be used yet.
  final List<String> models;

  final Duration latency;

  bool get isUsable => models.isNotEmpty;

  String get label => '${flavor.label} · ${baseUrl.host}:${baseUrl.port}';
}

/// Finds Ollama and LM Studio on the local network.
///
/// mDNS is unreliable on mobile — Android returns partial results and iOS gates it behind
/// a permission prompt that looks identical to a dead network when declined — so this
/// scans the obvious addresses instead. A scan of a /24 on two ports is 508 probes, which
/// is fast when they fail (a refused connection returns immediately) and bounded by the
/// concurrency limit when they do not.
class LocalServerDiscovery {
  const LocalServerDiscovery({
    required this.transport,
    this.probeTimeout = const Duration(seconds: 2),
    this.maxConcurrent = 32,
  });

  final HttpTransport transport;

  /// Deliberately short. A machine that is there answers in milliseconds on a LAN; a
  /// long timeout only makes a scan of 254 addresses feel broken.
  final Duration probeTimeout;

  final int maxConcurrent;

  /// Addresses worth trying before scanning a whole subnet: the emulator's alias for its
  /// host, loopback, and the router's usual address.
  static const List<String> shortlistHosts = [
    '10.0.2.2', // Android emulator -> host machine
    '127.0.0.1',
    'localhost',
  ];

  /// Probes the shortlist, then the subnet, emitting servers as they answer.
  ///
  /// A stream rather than a future so the UI can show the first result immediately
  /// instead of waiting for 254 timeouts to finish.
  Stream<DiscoveredServer> scan({String? subnetPrefix}) async* {
    final targets = <Uri>[
      for (final host in shortlistHosts)
        for (final flavor in LocalFlavor.values)
          Uri.parse('http://$host:${flavor.defaultPort}'),
      if (subnetPrefix != null)
        for (var host = 1; host <= 254; host++)
          for (final flavor in LocalFlavor.values)
            Uri.parse('http://$subnetPrefix.$host:${flavor.defaultPort}'),
    ];

    for (var i = 0; i < targets.length; i += maxConcurrent) {
      final batch = targets.skip(i).take(maxConcurrent);
      final found = await Future.wait(batch.map(probe));
      for (final server in found) {
        if (server != null) yield server;
      }
    }
  }

  /// Identifies whatever is listening at [baseUrl], or null if nothing usable is.
  ///
  /// Ollama and LM Studio both serve the OpenAI-compatible `/v1/models`, so that alone
  /// cannot tell them apart. Ollama additionally serves its own `/api/tags`, and that is
  /// what distinguishes them — the flavor decides whether the context window can be read
  /// later, so guessing it would produce a silently wrong capacity estimate.
  Future<DiscoveredServer?> probe(Uri baseUrl) async {
    final started = DateTime.now();

    final ollama = await _get(baseUrl.resolve('/api/tags'));
    if (ollama != null && ollama.ok) {
      final models = _ollamaModels(ollama);
      return DiscoveredServer(
        baseUrl: baseUrl,
        flavor: LocalFlavor.ollama,
        models: models,
        latency: DateTime.now().difference(started),
      );
    }

    final openAi = await _get(baseUrl.resolve('/v1/models'));
    if (openAi != null && openAi.ok) {
      return DiscoveredServer(
        baseUrl: baseUrl,
        flavor: LocalFlavor.lmStudio,
        models: _openAiModels(openAi),
        latency: DateTime.now().difference(started),
      );
    }

    return null;
  }

  Future<HttpReply?> _get(Uri url) async {
    try {
      return await transport.send(HttpCall(
        method: 'GET',
        url: url,
        headers: const {'accept': 'application/json'},
        timeout: probeTimeout,
      ));
    } on TransportException {
      // Nothing there. Every address in a subnet scan takes this path, so it must stay
      // silent and cheap.
      return null;
    }
  }

  static List<String> _ollamaModels(HttpReply reply) {
    final models = reply.json?['models'];
    if (models is! List) return const [];
    return models
        .whereType<Map<String, dynamic>>()
        .map((m) => (m['name'] as Object?).toString())
        .toList();
  }

  static List<String> _openAiModels(HttpReply reply) {
    final data = reply.json?['data'];
    if (data is! List) return const [];
    return data
        .whereType<Map<String, dynamic>>()
        .map((m) => (m['id'] as Object?).toString())
        .toList();
  }
}

/// How much recording a model's context window can hold in one pass.
///
/// The number users actually need when choosing a local model: a 4k-context model on a
/// laptop cannot take an hour-long meeting, and the failure mode without this is silent
/// truncation that produces a plausible note covering only the first ten minutes.
class ModelCapacity {
  const ModelCapacity._();

  /// Roughly 13k tokens per hour of speech, measured against real transcripts.
  static const int tokensPerHourOfSpeech = 13000;

  /// The system prompt plus the rendered schema.
  static const int promptOverheadTokens = 3500;

  /// Room for the model's own answer.
  static const int outputReserveTokens = 4000;

  static int minutesFor(int contextTokens) {
    final usable = contextTokens - promptOverheadTokens - outputReserveTokens;
    if (usable <= 0) return 0;
    return (usable / tokensPerHourOfSpeech * 60).round();
  }

  /// A phrase for the model picker. Says plainly when a model is too small to be useful
  /// rather than leaving the user to discover it after a two-hour meeting.
  static String describe(int contextTokens) {
    if (contextTokens <= 0) return 'Context window unknown';
    final minutes = minutesFor(contextTokens);
    if (minutes < 1) {
      return 'Too small for a transcript — notes would be written in sections';
    }
    if (minutes < 60) return 'About $minutes minutes of speech in one pass';
    final hours = minutes / 60;
    return 'About ${hours.toStringAsFixed(hours < 10 ? 1 : 0)} hours of speech '
        'in one pass';
  }

  /// Whether a recording of [durationMinutes] fits without splitting.
  static bool fitsInOnePass(int contextTokens, int durationMinutes) =>
      contextTokens > 0 && minutesFor(contextTokens) >= durationMinutes;
}
