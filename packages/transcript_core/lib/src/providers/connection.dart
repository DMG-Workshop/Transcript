import 'errors.dart';
import 'http_transport.dart';

/// The outcome of a connection test. Phase 0's centrepiece: enter a key or a LAN address,
/// press Test, and get an answer specific enough to act on.
class ConnectionResult {
  const ConnectionResult._({
    required this.ok,
    required this.summary,
    this.detail,
    this.remedy,
    this.models = const [],
    this.latency,
  });

  factory ConnectionResult.success({
    required String summary,
    List<String> models = const [],
    Duration? latency,
    String? detail,
  }) =>
      ConnectionResult._(
        ok: true,
        summary: summary,
        models: models,
        latency: latency,
        detail: detail,
      );

  factory ConnectionResult.failure({
    required String summary,
    String? detail,
    String? remedy,
  }) =>
      ConnectionResult._(
          ok: false, summary: summary, detail: detail, remedy: remedy);

  final bool ok;

  /// One line, shown in the settings row. "Connected · 14 models · 240 ms".
  final String summary;

  /// The provider's own words, when it gave any. Never contains the API key.
  final String? detail;

  /// What the user should do about it. Absent when there is nothing useful to say —
  /// better to say nothing than to guess.
  final String? remedy;

  /// Models the endpoint reports. For a local server this is the model picker's source.
  final List<String> models;

  final Duration? latency;
}

/// Maps HTTP failures to messages a user can act on, without leaking the key.
///
/// [isLocalEndpoint] changes the advice substantially: a refused connection to
/// api.openai.com means the network is down, while a refused connection to a LAN address
/// usually means the model server is bound to localhost or the phone is on another
/// network — and on both mobile platforms it can also mean the OS blocked the request
/// before it left the device, which produces exactly the same socket error.
ConnectionResult describeHttpFailure(
  HttpReply reply, {
  required String providerName,
  bool isLocalEndpoint = false,
}) {
  final body = reply.json;
  final detail = body == null
      ? _truncate(reply.body)
      : providerErrorMessage(body, '').trim().isEmpty
          ? _truncate(reply.body)
          : providerErrorMessage(body, '');

  return switch (reply.statusCode) {
    401 || 403 => ConnectionResult.failure(
        summary: '$providerName rejected the credentials',
        detail: detail,
        remedy: isLocalEndpoint
            ? 'The server is reachable but wants authentication. Check whether it was '
                'started with an API key set.'
            : 'Check the key is complete, has not been revoked, and belongs to an account '
                'with billing enabled.',
      ),
    404 => ConnectionResult.failure(
        summary: 'Endpoint not found',
        detail: detail,
        remedy: isLocalEndpoint
            ? 'Something is listening, but not at this path. Ollama serves /api and /v1; '
                'LM Studio serves /v1. Check the base URL.'
            : 'The base URL or model name is wrong for $providerName.',
      ),
    429 => ConnectionResult.failure(
        summary: 'Rate limited',
        detail: detail,
        remedy:
            'The credentials work. Wait for the limit to reset, or check the '
            'account\'s quota and billing status.',
      ),
    >= 500 => ConnectionResult.failure(
        summary: '$providerName returned a server error (${reply.statusCode})',
        detail: detail,
        remedy: 'Nothing to fix on this side. Retry shortly.',
      ),
    _ => ConnectionResult.failure(
        summary: '$providerName returned ${reply.statusCode}',
        detail: detail,
      ),
  };
}

/// Maps a transport failure — no HTTP status ever arrived — to actionable advice.
ConnectionResult describeTransportFailure(
  TransportException e, {
  required String providerName,
  bool isLocalEndpoint = false,
}) =>
    switch (e.kind) {
      TransportFailure.refused => ConnectionResult.failure(
          summary: 'Nothing is listening at that address',
          detail: e.message,
          remedy: isLocalEndpoint
              ? 'Three usual causes: the model server is not running; it is bound to '
                  '127.0.0.1 rather than 0.0.0.0 (for Ollama, set OLLAMA_HOST=0.0.0.0); or '
                  'the phone is on a different network from the computer. If the server is '
                  'definitely up, the phone may be blocking local network access — check '
                  'the app\'s Local Network permission on iOS.'
              : 'Check the device has a working connection.',
        ),
      TransportFailure.unresolved => ConnectionResult.failure(
          summary: 'Could not resolve that host',
          detail: e.message,
          remedy: isLocalEndpoint
              ? 'Use the computer\'s IP address rather than its .local hostname — mDNS '
                  'resolution is unreliable on mobile networks.'
              : 'Check the base URL for a typo.',
        ),
      TransportFailure.timeout => ConnectionResult.failure(
          summary: 'Timed out waiting for $providerName',
          detail: e.message,
          remedy: isLocalEndpoint
              ? 'A cold local model can take 30-60s to produce its first token. If this '
                  'keeps happening, load the model in the server before testing.'
              : 'Check the connection and retry.',
        ),
      TransportFailure.tls => ConnectionResult.failure(
          summary: 'TLS handshake failed',
          detail: e.message,
          remedy: isLocalEndpoint
              ? 'A self-signed certificate on a LAN endpoint will not be trusted. Use '
                  'plain http:// on the local network instead.'
              : null,
        ),
      TransportFailure.other => ConnectionResult.failure(
          summary: 'Could not reach $providerName',
          detail: e.message,
          remedy: isLocalEndpoint
              ? 'If the address is definitely right, the platform may be blocking the '
                  'request: iOS needs NSLocalNetworkUsageDescription and an ATS exception, '
                  'Android needs a cleartext exception for private address ranges.'
              : null,
        ),
    };

String? _truncate(String body, [int max = 240]) {
  final trimmed = body.trim();
  if (trimmed.isEmpty) return null;
  return trimmed.length <= max ? trimmed : '${trimmed.substring(0, max)}…';
}
