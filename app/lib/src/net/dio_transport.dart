import 'package:dio/dio.dart';
import 'package:transcript_core/transcript_core.dart';

/// Adapts `dio` to the core package's [HttpTransport] seam.
///
/// The core package deliberately has no HTTP dependency, so every adapter is testable
/// with a fake. This is the one place the real client is wired in, which is also the one
/// place to add logging, retry policy and cancellation.
class DioTransport implements HttpTransport {
  DioTransport({Dio? dio}) : _dio = dio ?? Dio() {
    _dio.interceptors.add(
      InterceptorsWrapper(
        onError: (e, handler) {
          // Never let a header carrying an API key reach a log sink or crash report.
          e.requestOptions.headers.removeWhere((k, _) => _secretHeaders.contains(k));
          handler.next(e);
        },
      ),
    );
  }

  static const _secretHeaders = {'x-api-key', 'authorization', 'x-goog-api-key'};

  final Dio _dio;

  @override
  Future<HttpReply> send(HttpCall call) async {
    try {
      final response = await _dio.requestUri<String>(
        call.url,
        data: call.jsonBody ?? call.bodyBytes,
        options: Options(
          method: call.method,
          headers: {
            ...call.headers,
            if (call.contentType != null) 'content-type': call.contentType,
          },
          responseType: ResponseType.plain,
          sendTimeout: call.timeout,
          receiveTimeout: call.timeout,
          // Handled by the adapters, which turn status codes into user-facing advice.
          validateStatus: (_) => true,
        ),
      );

      return HttpReply(
        response.statusCode ?? 0,
        response.data ?? '',
        headers: {
          for (final entry in response.headers.map.entries)
            entry.key: entry.value.join(', '),
        },
      );
    } on DioException catch (e) {
      throw TransportException(_classify(e), e.message ?? e.type.name);
    }
  }

  static TransportFailure _classify(DioException e) => switch (e.type) {
        DioExceptionType.connectionTimeout ||
        DioExceptionType.sendTimeout ||
        DioExceptionType.receiveTimeout =>
          TransportFailure.timeout,
        DioExceptionType.badCertificate => TransportFailure.tls,
        DioExceptionType.connectionError => _classifyConnectionError(e),
        _ => TransportFailure.other,
      };

  /// A refused connection and an OS-level block are the same socket error on both
  /// platforms, so the message text is the only signal available.
  static TransportFailure _classifyConnectionError(DioException e) {
    final message = e.message?.toLowerCase() ?? '';
    if (message.contains('refused')) return TransportFailure.refused;
    if (message.contains('failed host lookup') || message.contains('nodename')) {
      return TransportFailure.unresolved;
    }
    return TransportFailure.refused;
  }
}
