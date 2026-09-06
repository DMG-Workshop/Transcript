/// Local crash diagnostics.
///
/// Every crash reporting SDK worth using is also a data collection SDK, and adopting one
/// would turn the store privacy answer from "collects no data" into a page of
/// disclosures about a third party the user never chose. So reports are written to a
/// file on the device and go nowhere unless the user decides to send one. That is a
/// deliberate trade: slower diagnosis of field crashes, in exchange for the app's
/// central claim staying literally true.
///
/// What that buys only holds if the file itself is clean, so a report is assembled from
/// an allow-list — error, stack, breadcrumbs, build facts — and every free-text field
/// goes through a [Redactor] on the way in. Transcript text, note content and API keys
/// have no field to occupy.
library;

import 'redaction.dart';

/// How the failure reached the reporter. Worth recording: a synchronous framework error
/// and an unhandled async error usually have different causes even with identical text.
enum CrashOrigin {
  /// Thrown while Flutter was building, laying out or painting.
  framework('framework'),

  /// Escaped a Future or an isolate with no handler.
  unhandledAsync('unhandled-async'),

  /// Caught by the app and reported deliberately, because it was worth a record even
  /// though it was survivable.
  handled('handled');

  const CrashOrigin(this.id);
  final String id;
}

/// One thing that happened before the crash.
///
/// Breadcrumbs are the cheapest way to answer "what was it doing?" without recording
/// what the user was saying. Call sites pass event names — `recording started`,
/// `chunk 3 failed: timeout` — never content.
class Breadcrumb {
  const Breadcrumb({required this.at, required this.message});

  final DateTime at;
  final String message;

  Map<String, Object?> toJson() => {
        'at': at.toUtc().toIso8601String(),
        'message': message,
      };

  static Breadcrumb fromJson(Map<String, Object?> json) => Breadcrumb(
        at: DateTime.parse(json['at']! as String),
        message: json['message']! as String,
      );
}

/// A single crash, in the form it is written to disk.
class CrashReport {
  const CrashReport({
    required this.at,
    required this.origin,
    required this.summary,
    required this.detail,
    required this.appVersion,
    required this.platform,
    this.breadcrumbs = const [],
  });

  final DateTime at;
  final CrashOrigin origin;

  /// First line of the error, redacted. What a list of past crashes shows.
  final String summary;

  /// Error plus stack trace, redacted.
  final String detail;

  /// e.g. `0.1.0+1`. Without it a report is nearly useless.
  final String appVersion;

  /// e.g. `android 34`. Set by the app, which is the only layer that knows.
  final String platform;

  final List<Breadcrumb> breadcrumbs;

  Map<String, Object?> toJson() => {
        'at': at.toUtc().toIso8601String(),
        'origin': origin.id,
        'summary': summary,
        'detail': detail,
        'appVersion': appVersion,
        'platform': platform,
        'breadcrumbs': [for (final b in breadcrumbs) b.toJson()],
      };

  static CrashReport fromJson(Map<String, Object?> json) => CrashReport(
        at: DateTime.parse(json['at']! as String),
        origin: CrashOrigin.values.firstWhere(
          (o) => o.id == json['origin'],
          orElse: () => CrashOrigin.handled,
        ),
        summary: json['summary']! as String,
        detail: json['detail']! as String,
        appVersion: json['appVersion'] as String? ?? 'unknown',
        platform: json['platform'] as String? ?? 'unknown',
        breadcrumbs: [
          for (final b in (json['breadcrumbs'] as List<Object?>? ?? const []))
            Breadcrumb.fromJson(b! as Map<String, Object?>),
        ],
      );
}

/// Where reports are kept. Implemented over the filesystem in the app; faked in tests,
/// so the assembly and redaction logic runs without touching disk.
abstract class CrashSink {
  Future<void> write(CrashReport report);
}

/// A sink whose history can also be read back and cleared — what a diagnostics screen
/// needs to show the user what is being held and let them delete it.
///
/// Separate from [CrashSink] because the crash path itself only ever writes, and it
/// should not be able to do anything else while handling a crash.
abstract class CrashArchive implements CrashSink {
  /// Every stored report, oldest first.
  Future<List<CrashReport>> read();

  Future<void> clear();
}

/// Renders reports as the text a user would share.
///
/// Rendered rather than raw JSON because the point of keeping reports local is that the
/// person sending one can read exactly what they are sending first.
String renderCrashBundle(List<CrashReport> reports) {
  if (reports.isEmpty) return 'No crash reports.';

  final out = StringBuffer()
    ..writeln('Transcript diagnostics')
    ..writeln('${reports.length} report(s). No recording or transcript text is '
        'included, and API keys are removed.')
    ..writeln();

  for (final report in reports.reversed) {
    out
      ..writeln(
          '— ${report.at.toUtc().toIso8601String()} (${report.origin.id}) —')
      ..writeln('app ${report.appVersion} on ${report.platform}')
      ..writeln(report.detail);
    if (report.breadcrumbs.isNotEmpty) {
      out.writeln('Recent events:');
      for (final crumb in report.breadcrumbs) {
        out.writeln(
            '  ${crumb.at.toUtc().toIso8601String()}  ${crumb.message}');
      }
    }
    out.writeln();
  }

  return out.toString();
}

/// Assembles redacted crash reports and hands them to a [CrashSink].
class CrashReporter {
  CrashReporter({
    required Redactor redactor,
    required CrashSink sink,
    required this.appVersion,
    required this.platform,
    this.breadcrumbCapacity = 25,
    DateTime Function()? clock,
  })  : _redactor = redactor,
        _sink = sink,
        _clock = clock ?? DateTime.now;

  final Redactor _redactor;
  final CrashSink _sink;
  final DateTime Function() _clock;

  final String appVersion;
  final String platform;

  /// Only the most recent events are kept. A ring bounds both the file size and how far
  /// back a report can reach into a session.
  final int breadcrumbCapacity;

  /// Length beyond which a breadcrumb is truncated. A call site that accidentally passes
  /// a transcript line instead of an event name should lose the transcript, not commit
  /// it to disk — belt and braces alongside redaction.
  static const int maxBreadcrumbLength = 120;

  final List<Breadcrumb> _breadcrumbs = [];

  List<Breadcrumb> get breadcrumbs => List.unmodifiable(_breadcrumbs);

  void leaveBreadcrumb(String message) {
    var text = _redactor.scrub(message);
    if (text.length > maxBreadcrumbLength) {
      text = '${text.substring(0, maxBreadcrumbLength)}…';
    }
    _breadcrumbs.add(Breadcrumb(at: _clock(), message: text));
    if (_breadcrumbs.length > breadcrumbCapacity) {
      _breadcrumbs.removeRange(0, _breadcrumbs.length - breadcrumbCapacity);
    }
  }

  /// Builds a report and writes it. Never throws: a failure to record a crash must not
  /// become a second crash, and there is nothing useful to do about it at this point.
  Future<CrashReport?> report(
    Object error, {
    StackTrace? stack,
    CrashOrigin origin = CrashOrigin.handled,
  }) async {
    try {
      final report = build(error, stack: stack, origin: origin);
      await _sink.write(report);
      return report;
    } catch (_) {
      return null;
    }
  }

  /// The assembly step on its own, so tests can assert on the content without a sink.
  CrashReport build(
    Object error, {
    StackTrace? stack,
    CrashOrigin origin = CrashOrigin.handled,
  }) {
    final scrubbed = _redactor.scrub(error.toString());
    return CrashReport(
      at: _clock(),
      origin: origin,
      summary: _firstLine(scrubbed),
      detail: _redactor.scrubError(error, stack),
      appVersion: appVersion,
      platform: platform,
      breadcrumbs: List.of(_breadcrumbs),
    );
  }

  static String _firstLine(String value) {
    final line = value.split('\n').first.trim();
    return line.length <= 200 ? line : '${line.substring(0, 200)}…';
  }
}
