import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:transcript_app/src/onboarding/onboarding_screen.dart';
import 'package:transcript_app/src/privacy/crash_log.dart';
import 'package:transcript_app/src/recording/recording_controller.dart';
import 'package:transcript_app/src/screens/privacy_screen.dart';
import 'package:transcript_app/src/screens/record_screen.dart';
import 'package:transcript_app/src/settings/provider_config.dart';
import 'package:transcript_app/src/settings/secure_key_store.dart';
import 'package:transcript_core/transcript_core.dart';

void main() {
  group('the redacting key store', () {
    test('a key already in storage becomes scrubbable when it is read',
        () async {
      // The case that matters on every launch after the first: the key was saved in a
      // previous process, so nothing has told this run's redactor about it until
      // something reads it back.
      final stored = InMemoryKeyStore();
      await stored.write('anthropic', 'sk-ant-api03-REALKEYVALUE');

      final redactor = Redactor();
      await RedactingKeyStore(stored, redactor).read('anthropic');

      expect(redactor.scrub('failed with sk-ant-api03-REALKEYVALUE'),
          isNot(contains('REALKEYVALUE')));
    });

    test('writing a key registers it immediately', () async {
      final redactor = Redactor();
      final store = RedactingKeyStore(InMemoryKeyStore(), redactor);

      await store.write('openai', 'sk-proj-Ab3xQ91ZZmKlpQr77TzV0s');

      expect(redactor.secretCount, 1);
    });

    test('deleting a key stops it being tracked', () async {
      final redactor = Redactor();
      final store = RedactingKeyStore(InMemoryKeyStore(), redactor);
      await store.write('openai', 'sk-proj-Ab3xQ91ZZmKlpQr77TzV0s');

      await store.delete('openai');

      expect(redactor.secretCount, 0,
          reason: 'a removed key is no longer a secret worth carrying');
    });

    test('it still behaves like a key store', () async {
      final store = RedactingKeyStore(InMemoryKeyStore(), Redactor());

      expect(await store.has('gemini'), isFalse);
      await store.write('gemini', 'AIzaSyD9xTf01Kd8mnQ2LpZzX4bV7cRs6WuYtJq');
      expect(await store.has('gemini'), isTrue);
      expect(await store.read('gemini'), startsWith('AIza'));
    });
  });

  group('crash reports on disk', () {
    late Directory root;

    setUp(() => root = Directory.systemTemp.createTempSync('crash-test-'));
    tearDown(() => root.deleteSync(recursive: true));

    CrashReport report(String summary) => CrashReport(
          at: DateTime.utc(2026, 9, 6),
          origin: CrashOrigin.handled,
          summary: summary,
          detail: '$summary\n#0 main',
          appVersion: '0.1.0+1',
          platform: 'ios 18',
        );

    test('reports survive being written and read back', () async {
      final sink = FileCrashSink(root: root);

      await sink.write(report('first'));
      await sink.write(report('second'));

      final stored = await FileCrashSink(root: root).read();
      expect(stored.map((r) => r.summary), ['first', 'second']);
    });

    test('reading a missing file is empty, not an error', () async {
      expect(await FileCrashSink(root: root).read(), isEmpty);
    });

    test('only the most recent reports are kept', () async {
      final sink = FileCrashSink(root: root, keepMostRecent: 3);

      for (var i = 0; i < 8; i++) {
        await sink.write(report('crash $i'));
      }

      final stored = await sink.read();
      expect(stored.length, 3);
      expect(stored.last.summary, 'crash 7');
    });

    test('a truncated line does not make the history unreadable', () async {
      // What a process killed mid-write leaves behind. Losing one report is fine;
      // losing every earlier one because of it is not.
      final sink = FileCrashSink(root: root);
      await sink.write(report('good'));
      await File('${root.path}/crash-reports.jsonl')
          .writeAsString('{"at":"2026-09', mode: FileMode.append);

      final stored = await sink.read();
      expect(stored.single.summary, 'good');
    });

    test('clearing removes everything', () async {
      final sink = FileCrashSink(root: root);
      await sink.write(report('first'));

      await sink.clear();

      expect(await sink.read(), isEmpty);
    });

    test('the shared bundle says what it does and does not contain', () {
      final text = renderCrashBundle([report('boom')]);

      expect(text, contains('boom'));
      expect(text, contains('0.1.0+1'));
      expect(text, contains('No recording or transcript text'));
    });

    test('an empty bundle says so rather than sharing a blank file', () {
      expect(renderCrashBundle([]), 'No crash reports.');
    });
  });

  group('spoken durations', () {
    test('seconds alone are named as seconds', () {
      expect(spokenDuration(const Duration(seconds: 32)), '32 seconds');
    });

    test('one of anything is singular', () {
      expect(spokenDuration(const Duration(minutes: 1, seconds: 1)),
          '1 minute 1 second');
    });

    test('minutes and seconds are both spoken', () {
      expect(spokenDuration(const Duration(minutes: 5, seconds: 32)),
          '5 minutes 32 seconds');
    });

    test('an exact minute does not say zero seconds', () {
      expect(spokenDuration(const Duration(minutes: 5)), '5 minutes');
    });

    test('seconds are dropped once there is an hour, since they are noise', () {
      expect(spokenDuration(const Duration(hours: 1, minutes: 2, seconds: 3)),
          '1 hour 2 minutes');
    });

    test('zero is a length, not an empty string', () {
      expect(spokenDuration(Duration.zero), '0 seconds');
    });
  });

  group('onboarding', () {
    Future<void> pump(WidgetTester tester,
        {required VoidCallback onDone}) async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            settingsStoreProvider.overrideWithValue(SettingsStore(prefs)),
          ],
          child: MaterialApp(home: OnboardingScreen(onDone: onDone)),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('it leads with what the app does, not with a key request',
        (tester) async {
      await pump(tester, onDone: () {});

      expect(find.text('Record anything worth remembering'), findsOneWidget);
      expect(find.textContaining('API key'), findsNothing,
          reason:
              'asking for a key on page one is how a BYOK app loses people');
    });

    testWidgets('the key explanation says it works without one',
        (tester) async {
      await pump(tester, onDone: () {});

      await tester.tap(find.text('Next'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Next'));
      await tester.pumpAndSettle();

      expect(find.text('You bring the AI'), findsOneWidget);
      expect(find.textContaining('no subscription'), findsOneWidget);
    });

    testWidgets('the last page states the posture the app will actually use',
        (tester) async {
      await pump(tester, onDone: () {});

      for (var i = 0; i < 3; i++) {
        await tester.tap(find.text('Next'));
        await tester.pumpAndSettle();
      }

      // Nothing configured yet, so the default pairing is on-device recognition with
      // no notes provider — which is a cloud posture the moment one is chosen, and the
      // screen has to say the honest thing rather than a marketing line.
      expect(find.text('Where your recording goes'), findsOneWidget);
      expect(find.text('Start recording'), findsOneWidget);
    });

    testWidgets('finishing reports back so the flow is not shown again',
        (tester) async {
      var done = 0;
      await pump(tester, onDone: () => done++);

      for (var i = 0; i < 3; i++) {
        await tester.tap(find.text('Next'));
        await tester.pumpAndSettle();
      }
      await tester.tap(find.text('Start recording'));
      await tester.pumpAndSettle();

      expect(done, 1);
    });

    testWidgets('skipping is allowed and counts as done', (tester) async {
      var done = 0;
      await pump(tester, onDone: () => done++);

      await tester.tap(find.text('Skip'));
      await tester.pumpAndSettle();

      expect(done, 1);
    });

    test('the flag is recorded rather than inferred from configuration',
        () async {
      SharedPreferences.setMockInitialValues({});
      final store = SettingsStore(await SharedPreferences.getInstance());

      expect(store.hasOnboarded, isFalse);
      await store.setOnboarded();
      expect(store.hasOnboarded, isTrue);
    });
  });

  group('the privacy screen', () {
    setUp(() {
      final view = TestWidgetsFlutterBinding.ensureInitialized()
          .platformDispatcher
          .implicitView!;
      view.physicalSize = const Size(1200, 2600);
      view.devicePixelRatio = 1.0;
    });

    tearDown(() {
      final view = TestWidgetsFlutterBinding.ensureInitialized()
          .platformDispatcher
          .implicitView!;
      view.resetPhysicalSize();
      view.resetDevicePixelRatio();
    });

    // In memory rather than on disk: a widget test's clock is fake, so real file I/O
    // during a frame never completes. That hang is exactly what the CrashArchive seam
    // exists to keep out of the widget layer.
    Future<void> pump(WidgetTester tester, InMemoryCrashArchive archive) async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final redactor = Redactor();

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            settingsStoreProvider.overrideWithValue(SettingsStore(prefs)),
            diagnosticsProvider.overrideWithValue(
              Diagnostics(
                redactor: redactor,
                reporter: CrashReporter(
                  redactor: redactor,
                  sink: archive,
                  appVersion: '0.1.0+1',
                  platform: 'test',
                ),
                archive: archive,
              ),
            ),
          ],
          child: const MaterialApp(home: PrivacyScreen()),
        ),
      );
      await tester.pumpAndSettle();
    }

    CrashReport report(String summary) => CrashReport(
          at: DateTime.utc(2026, 9, 6),
          origin: CrashOrigin.framework,
          summary: summary,
          detail: '$summary\n#0 main',
          appVersion: '0.1.0+1',
          platform: 'test',
        );

    testWidgets('every disclosed practice is on the screen', (tester) async {
      await pump(tester, InMemoryCrashArchive());

      for (final practice in PrivacyDisclosure.practices) {
        expect(find.text(practice.label), findsOneWidget,
            reason:
                '${practice.id} is disclosed in the docs but not in the app');
      }
    });

    testWidgets('with no crashes it says so plainly', (tester) async {
      await pump(tester, InMemoryCrashArchive());

      expect(find.textContaining('Nothing has crashed'), findsOneWidget);
    });

    testWidgets('a stored crash is listed and says it was not sent anywhere',
        (tester) async {
      final archive = InMemoryCrashArchive()
        ..reports.add(report('RangeError: index out of range'));

      await pump(tester, archive);

      expect(find.text('RangeError: index out of range'), findsOneWidget);
      expect(find.textContaining('Nothing has been sent anywhere'),
          findsOneWidget);
    });

    testWidgets('deleting clears the reports', (tester) async {
      final archive = InMemoryCrashArchive()..reports.add(report('boom'));

      await pump(tester, archive);
      await tester.tap(find.text('Delete all'));
      await tester.pumpAndSettle();

      expect(archive.reports, isEmpty);
      expect(find.textContaining('Nothing has crashed'), findsOneWidget);
    });
  });
}

/// A [CrashArchive] with no filesystem behind it.
class InMemoryCrashArchive implements CrashArchive {
  final List<CrashReport> reports = [];

  @override
  Future<void> write(CrashReport report) async => reports.add(report);

  @override
  Future<List<CrashReport>> read() async => List.of(reports);

  @override
  Future<void> clear() async => reports.clear();
}
