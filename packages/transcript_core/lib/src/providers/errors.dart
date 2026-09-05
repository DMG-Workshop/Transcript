/// A provider returned a response we cannot use. Carries enough to show the user
/// something true, and never carries the API key.
class ProviderException implements Exception {
  const ProviderException(
    this.provider,
    this.statusCode,
    this.message, {
    this.retryAfter,
  });

  final String provider;
  final int statusCode;
  final String message;

  /// From the provider's `Retry-After` header. Guessing a shorter delay than a rate
  /// limiter asked for gets the retry rejected too, so the queue honours this over its
  /// own exponential schedule.
  final Duration? retryAfter;

  @override
  String toString() => '$provider ($statusCode): $message';
}

/// Pulls the human-readable message out of a provider error body.
///
/// Anthropic and OpenAI use `{"error": {"message": ...}}`; Ollama and LM Studio use
/// `{"error": "..."}`. Falls back to the raw body, which is often an HTML error page from
/// a proxy in front of a local model server.
String providerErrorMessage(Map<String, dynamic>? body, String rawBody) {
  if (body != null) {
    final error = body['error'];
    if (error is Map<String, dynamic> && error['message'] is String) {
      return error['message'] as String;
    }
    if (error is String) return error;
    if (body['message'] is String) return body['message'] as String;
  }
  return rawBody;
}
