import 'package:test/test.dart';
import 'package:transcript_core/transcript_core.dart';

/// Collects reports in memory so assembly and redaction are testable without disk.
class FakeCrashSink implements CrashSink {
  final List<CrashReport> written = [];

  @override
  Future<void> write(CrashReport report) async => written.add(report);
}

class ExplodingSink implements CrashSink {
  @override
  Future<void> write(CrashReport report) async =>
      throw StateError('disk is full');
}

void main() {
  group('redaction', () {
    test('a registered key is removed wherever it appears', () {
      final redactor = Redactor(secrets: ['sk-ant-api03-REALKEYVALUE']);

      final out = redactor.scrub(
        'POST failed: {"error":"invalid key sk-ant-api03-REALKEYVALUE"}',
      );

      expect(out, isNot(contains('REALKEYVALUE')));
      expect(out, contains('[redacted: api key]'));
    });

    test('a key nobody registered is still caught by its shape', () {
      // The case that matters: a key typed into the field but not yet saved, so the
      // redactor was never told about it, reaching an exception message.
      final out = Redactor().scrub('401 for sk-proj-Ab3xQ91ZZmKlpQr77TzV0s');

      expect(out, isNot(contains('Ab3xQ91ZZmKlpQr77TzV0s')));
      expect(out, contains('[redacted: api key]'));
    });

    test('Google and Hugging Face key shapes are covered too', () {
      final out = Redactor().scrub(
        'GET ...?key=AIzaSyD9xTf01Kd8mnQ2LpZzX4bV7cRs6WuYtJq and hf_QwErTyUiOpAsDfGh',
      );

      expect(out, isNot(contains('AIzaSyD9')));
      expect(out, isNot(contains('QwErTyUiOpAsDfGh')));
    });

    test('an authorization header keeps its name and loses its value', () {
      final out =
          Redactor().scrub('authorization: Bearer opaque-token-value-42');

      expect(out, isNot(contains('opaque-token-value-42')));
      expect(out, contains('authorization'),
          reason: 'which header failed is the useful half');
      expect(out, contains('[redacted: authorization header]'));
    });

    test('a key in a query string is stripped but the URL stays readable', () {
      final out = Redactor().scrub(
        'https://generativelanguage.googleapis.com/v1/models:generate?key=SUPERSECRETVALUE',
      );

      expect(out, isNot(contains('SUPERSECRETVALUE')));
      expect(out, contains('generativelanguage.googleapis.com'),
          reason: 'the endpoint is what makes the report diagnosable');
      expect(out, contains('?key='));
    });

    test('a home directory is replaced but the rest of the path survives', () {
      final out = Redactor().scrub(
        'FileSystemException: /Users/danielle/Library/Application Support/db.sqlite',
      );

      expect(out, isNot(contains('danielle')));
      expect(out, contains('Library/Application Support/db.sqlite'));
    });

    test('windows paths are covered as well as posix', () {
      final out = Redactor().scrub(r'C:\Users\danielle\AppData\Local\cache');

      expect(out, isNot(contains('danielle')));
      expect(out, contains(r'\AppData\Local\cache'));
    });

    test('email addresses go, since they identify a person', () {
      final out = Redactor().scrub('billing error for someone@example.com');

      expect(out, isNot(contains('someone@example.com')));
    });

    test('an overlapping secret is fully removed, not left in fragments', () {
      // If the shorter secret were replaced first, the tail of the longer one would
      // survive in the output — the exact failure this ordering exists to prevent.
      final redactor = Redactor(secrets: [
        'abcdefgh12345678',
        'abcdefgh12345678-with-more-suffix',
      ]);

      final out = redactor.scrub('key=abcdefgh12345678-with-more-suffix end');

      expect(out, isNot(contains('with-more-suffix')));
      expect(out, contains('end'));
    });

    test(
        'a secret too short to be distinctive is refused rather than misapplied',
        () {
      final redactor = Redactor(secrets: ['abc']);

      expect(redactor.secretCount, 0);
      expect(redactor.scrub('abc appears in abcdefg and in fabric'),
          'abc appears in abcdefg and in fabric',
          reason:
              'scrubbing three characters everywhere would destroy the report');
    });

    test('ordinary text is left alone', () {
      const message =
          'RangeError (index): Invalid value: Not in inclusive range 0..3: 7';

      expect(Redactor().scrub(message), message);
    });

    test('forgetting a key stops it being tracked', () {
      final redactor = Redactor(secrets: ['sk-ant-api03-REALKEYVALUE']);
      redactor.forget('sk-ant-api03-REALKEYVALUE');

      expect(redactor.secretCount, 0);
    });

    test('scrubError folds in the stack trace', () {
      final redactor = Redactor(secrets: ['sk-ant-api03-REALKEYVALUE']);

      final out = redactor.scrubError(
        StateError('bad key sk-ant-api03-REALKEYVALUE'),
        StackTrace.fromString('#0 main (/Users/danielle/app/lib/main.dart:1)'),
      );

      expect(out, isNot(contains('REALKEYVALUE')));
      expect(out, isNot(contains('danielle')));
      expect(out, contains('main.dart'));
    });
  });

  group('crash reports', () {
    CrashReporter reporter(
      CrashSink sink, {
      Redactor? redactor,
      int capacity = 25,
    }) =>
        CrashReporter(
          redactor:
              redactor ?? Redactor(secrets: ['sk-ant-api03-REALKEYVALUE']),
          sink: sink,
          appVersion: '0.1.0+1',
          platform: 'android 34',
          breadcrumbCapacity: capacity,
        );

    test('a report carries the build facts a triage needs', () async {
      final sink = FakeCrashSink();
      await reporter(sink).report(StateError('boom'));

      final report = sink.written.single;
      expect(report.appVersion, '0.1.0+1');
      expect(report.platform, 'android 34');
      expect(report.summary, contains('boom'));
    });

    test('a key in the error never reaches the sink', () async {
      final sink = FakeCrashSink();

      await reporter(sink).report(
        StateError('request rejected: sk-ant-api03-REALKEYVALUE'),
        stack: StackTrace.fromString('#0 send (/Users/danielle/x.dart:9)'),
      );

      final report = sink.written.single;
      expect(report.summary, isNot(contains('REALKEYVALUE')));
      expect(report.detail, isNot(contains('REALKEYVALUE')));
      expect(report.detail, isNot(contains('danielle')));
    });

    test('breadcrumbs are redacted as they are recorded, not at write time',
        () {
      // If redaction only happened on write, a secret would still sit in memory in a
      // list that a debugger, a memory dump or a later feature could read.
      final crashReporter = reporter(FakeCrashSink())
        ..leaveBreadcrumb('auth failed with sk-ant-api03-REALKEYVALUE');

      expect(crashReporter.breadcrumbs.single.message,
          isNot(contains('REALKEYVALUE')));
    });

    test('a breadcrumb carrying content is truncated rather than stored whole',
        () {
      final crashReporter = reporter(FakeCrashSink())
        ..leaveBreadcrumb('x' * 500);

      expect(
        crashReporter.breadcrumbs.single.message.length,
        lessThanOrEqualTo(CrashReporter.maxBreadcrumbLength + 1),
      );
    });

    test('only the most recent breadcrumbs are kept', () {
      final crashReporter = reporter(FakeCrashSink(), capacity: 3);
      for (var i = 0; i < 10; i++) {
        crashReporter.leaveBreadcrumb('event $i');
      }

      expect(crashReporter.breadcrumbs.length, 3);
      expect(crashReporter.breadcrumbs.last.message, 'event 9');
      expect(crashReporter.breadcrumbs.first.message, 'event 7');
    });

    test('the report snapshots breadcrumbs rather than aliasing them',
        () async {
      final sink = FakeCrashSink();
      final crashReporter = reporter(sink)
        ..leaveBreadcrumb('recording started');

      await crashReporter.report(StateError('boom'));
      crashReporter.leaveBreadcrumb('happened after the crash');

      expect(sink.written.single.breadcrumbs.length, 1);
    });

    test('a sink that fails does not turn one crash into two', () async {
      // This runs inside a crash handler. Throwing here would replace a diagnosable
      // failure with an undiagnosable one.
      final result = await reporter(ExplodingSink()).report(StateError('boom'));

      expect(result, isNull);
    });

    test('a report round-trips through JSON', () async {
      final sink = FakeCrashSink();
      final crashReporter = reporter(sink)
        ..leaveBreadcrumb('recording started');
      await crashReporter.report(
        StateError('boom'),
        origin: CrashOrigin.framework,
      );

      final original = sink.written.single;
      final restored = CrashReport.fromJson(original.toJson());

      expect(restored.origin, CrashOrigin.framework);
      expect(restored.summary, original.summary);
      expect(restored.appVersion, original.appVersion);
      expect(restored.at.toUtc(), original.at.toUtc());
      expect(restored.breadcrumbs.single.message, 'recording started');
    });

    test('an unknown origin in a stored file does not break reading it', () {
      final json = {
        'at': DateTime.utc(2026).toIso8601String(),
        'origin': 'from-a-future-version',
        'summary': 's',
        'detail': 'd',
        'appVersion': '0.1.0',
        'platform': 'ios 18',
      };

      expect(CrashReport.fromJson(json).origin, CrashOrigin.handled);
    });
  });

  group('privacy disclosure', () {
    test('nothing is sent to a publisher server, because there is none', () {
      expect(PrivacyDisclosure.collectsNothing, isTrue);
    });

    test('every practice says something a person can read', () {
      for (final practice in PrivacyDisclosure.practices) {
        expect(practice.label, isNotEmpty);
        expect(practice.plainLanguage.length, greaterThan(40),
            reason: '${practice.id} needs a real explanation, not a label');
      }
    });

    test('practice ids are unique, since the doc anchors on them', () {
      final ids = PrivacyDisclosure.practices.map((p) => p.id).toList();

      expect(ids.toSet().length, ids.length);
    });

    test('audio and transcripts are the rows that depend on configuration', () {
      final ids =
          PrivacyDisclosure.configurationDependent.map((p) => p.id).toSet();

      expect(ids, containsAll(['audio', 'transcripts']));
      expect(ids, isNot(contains('notes')),
          reason: 'notes never leave the device under any configuration');
      expect(ids, isNot(contains('api-keys')));
    });

    test('keys and diagnostics are pinned to the device', () {
      expect(PrivacyDisclosure.byId('api-keys').destination,
          DataDestination.device);
      expect(PrivacyDisclosure.byId('diagnostics').destination,
          DataDestination.device);
    });

    test('the store answers state the no-backend reasoning, not just "no"', () {
      expect(PrivacyDisclosure.appStoreDataCollectionAnswer,
          contains('no backend'));
      expect(PrivacyDisclosure.playDataSafetyAnswer,
          contains('No data collected'));
    });
  });
}
