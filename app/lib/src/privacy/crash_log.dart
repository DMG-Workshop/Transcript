import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:transcript_core/transcript_core.dart';

/// Crash reports on disk, and the wiring that puts them there.
///
/// Reports go to a file in the app's own support directory and are never uploaded.
/// That is what lets the store listing say "collects no data" without an asterisk, and
/// it means a report is something the user can read in full before deciding to send it
/// — which is a stronger privacy position than any promise about a third-party SDK.

/// Appends reports to a JSON-lines file, newest last, oldest dropped.
class FileCrashSink implements CrashArchive {
  FileCrashSink({required Directory root, this.keepMostRecent = 20})
      : _file = File(p.join(root.path, 'crash-reports.jsonl'));

  final File _file;

  /// A bounded file: enough history to spot a repeating crash, small enough that it
  /// never becomes a storage problem on a device already holding recordings.
  final int keepMostRecent;

  @override
  Future<void> write(CrashReport report) async {
    final reports = await read();
    reports.add(report);
    await _replaceWith(reports);
  }

  /// Every stored report, oldest first. A line that cannot be parsed is skipped rather
  /// than throwing: a half-written line from a process killed mid-write must not make
  /// the whole history unreadable.
  @override
  Future<List<CrashReport>> read() async {
    if (!_file.existsSync()) return [];
    final out = <CrashReport>[];
    for (final line in await _file.readAsLines()) {
      if (line.trim().isEmpty) continue;
      try {
        out.add(
          CrashReport.fromJson(jsonDecode(line) as Map<String, Object?>),
        );
      } catch (_) {
        continue;
      }
    }
    return out;
  }

  @override
  Future<void> clear() async {
    if (_file.existsSync()) await _file.delete();
  }

  Future<void> _replaceWith(List<CrashReport> reports) async {
    final kept = reports.length <= keepMostRecent
        ? reports
        : reports.sublist(reports.length - keepMostRecent);
    final text = kept.map((r) => jsonEncode(r.toJson())).join('\n');
    await _file.parent.create(recursive: true);
    await _file.writeAsString(text.isEmpty ? '' : '$text\n', flush: true);
  }
}

/// Holds everything the app needs to record a crash, built once at startup.
class Diagnostics {
  const Diagnostics({
    required this.redactor,
    required this.reporter,
    required this.archive,
  });

  final Redactor redactor;
  final CrashReporter reporter;

  /// Typed as the interface, not [FileCrashSink]: the diagnostics screen only reads and
  /// clears, and keeping it off the concrete type is what lets it be tested without a
  /// filesystem.
  final CrashArchive archive;
}

/// Builds the reporter and installs it as Flutter's error handler.
///
/// Both hooks are needed and they catch different things: [FlutterError.onError] sees
/// failures during build, layout and paint, while [PlatformDispatcher.onError] is the
/// last stop for anything that escapes a Future — which is where a failing network call
/// or a background transcription would land.
Future<Diagnostics> installCrashReporting({Redactor? redactor}) async {
  final activeRedactor = redactor ?? Redactor();
  final root = Directory(
    p.join((await getApplicationSupportDirectory()).path, 'diagnostics'),
  );
  final sink = FileCrashSink(root: root);

  final info = await PackageInfo.fromPlatform();
  final reporter = CrashReporter(
    redactor: activeRedactor,
    sink: sink,
    appVersion: '${info.version}+${info.buildNumber}',
    platform: '${Platform.operatingSystem} ${Platform.operatingSystemVersion}',
  );

  final previousOnError = FlutterError.onError;
  FlutterError.onError = (details) {
    unawaited(
      reporter.report(
        details.exception,
        stack: details.stack,
        origin: CrashOrigin.framework,
      ),
    );
    // Still print it: in debug this is how a developer sees the failure at all, and
    // swallowing it would make the app harder to work on for no privacy gain.
    previousOnError?.call(details);
  };

  PlatformDispatcher.instance.onError = (error, stack) {
    unawaited(
      reporter.report(error, stack: stack, origin: CrashOrigin.unhandledAsync),
    );
    // False lets the platform's own handler run as well, so a fatal error still
    // terminates rather than leaving the app wedged in an unknown state.
    return false;
  };

  return Diagnostics(
    redactor: activeRedactor,
    reporter: reporter,
    archive: sink,
  );
}

/// Overridden in `main` once [installCrashReporting] has run. Reading it without that
/// override is a programming error rather than something to paper over: a screen that
/// silently reports into a null reporter would look like it worked.
final diagnosticsProvider = Provider<Diagnostics>(
  (ref) => throw UnimplementedError('diagnosticsProvider must be overridden'),
);

/// The reports currently held on the device.
///
/// A provider rather than a read in the screen's `initState`: reading a file from a
/// widget's lifecycle is real async I/O in the middle of a frame, which is both a
/// layering problem and — in a widget test, where the clock is fake — a hang.
final crashReportsProvider = FutureProvider<List<CrashReport>>(
  (ref) => ref.watch(diagnosticsProvider).archive.read(),
);
