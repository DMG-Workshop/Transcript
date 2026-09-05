import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:transcript_app/src/recording/recording_controller.dart';
import 'package:transcript_app/src/screens/record_screen.dart';
import 'package:transcript_app/src/widgets/waveform.dart';

void main() {
  Future<void> pump(WidgetTester tester, RecordState state,
      {List<double> levels = const []}) async {
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: Scaffold(body: RecordBody(state: state, levels: levels)),
        ),
      ),
    );
    // pump, not pumpAndSettle: an indeterminate progress indicator animates forever, so
    // waiting for the tree to go quiet would never return.
    await tester.pump();
  }

  testWidgets('at rest, it says what the app does with your audio', (tester) async {
    await pump(tester, const RecordIdle());

    expect(find.text('Ready to record'), findsOneWidget);
    expect(find.textContaining('straight from this device'), findsOneWidget);
  });

  testWidgets('while recording, the elapsed time and waveform are visible',
      (tester) async {
    await pump(
      tester,
      const RecordActive(elapsed: Duration(minutes: 2, seconds: 7)),
      levels: [0.2, 0.6, 0.4],
    );

    expect(find.text('02:07'), findsOneWidget);
    expect(find.byType(Waveform), findsOneWidget,
        reason: 'the waveform is what proves the app is actually listening');
  });

  testWidgets('live recognition shows text as it arrives; cloud says listening',
      (tester) async {
    await pump(
      tester,
      const RecordActive(elapsed: Duration(seconds: 4), liveText: 'Morning everyone'),
    );
    expect(find.text('Morning everyone'), findsOneWidget);

    await pump(tester, const RecordActive(elapsed: Duration(seconds: 4)));
    expect(find.text('Listening'), findsOneWidget,
        reason: 'cloud transcription has nothing to show yet, and should not pretend');
  });

  testWidgets('an interruption is explained, not left as silent dead air',
      (tester) async {
    await pump(
      tester,
      const RecordActive(
        elapsed: Duration(minutes: 3),
        interrupted: true,
        interruptionReason: 'interrupted by another app',
      ),
    );

    expect(find.textContaining('Paused'), findsOneWidget);
    expect(find.textContaining('interrupted by another app'), findsOneWidget);
    expect(find.textContaining('continues automatically'), findsOneWidget,
        reason: 'a running timer over silence with no explanation reads as broken');
  });

  testWidgets('an uninterrupted recording shows no pause banner', (tester) async {
    await pump(tester, const RecordActive(elapsed: Duration(minutes: 3)));
    expect(find.textContaining('Paused'), findsNothing);
  });

  testWidgets('transcription progress is a real fraction, not a spinner',
      (tester) async {
    await pump(
      tester,
      const RecordProcessing(label: 'Transcribing 2 of 5', fraction: 0.4),
    );

    expect(find.text('Transcribing 2 of 5'), findsOneWidget);
    final bar = tester.widget<LinearProgressIndicator>(
        find.byType(LinearProgressIndicator));
    expect(bar.value, 0.4);
  });

  testWidgets('structuring has no fraction and does not fake one', (tester) async {
    await pump(tester, const RecordProcessing(label: 'Writing notes'));

    final bar = tester.widget<LinearProgressIndicator>(
        find.byType(LinearProgressIndicator));
    expect(bar.value, isNull);
  });

  testWidgets('an error shows the remedy, not just the failure', (tester) async {
    await pump(
      tester,
      const RecordError(
        'Microphone access was declined.',
        remedy: 'You can grant access in Settings.',
      ),
    );

    expect(find.text('Microphone access was declined.'), findsOneWidget);
    expect(find.text('You can grant access in Settings.'), findsOneWidget);
  });

  testWidgets('when structuring fails, the transcript is still offered',
      (tester) async {
    await pump(
      tester,
      const RecordError(
        'The notes could not be written.',
        remedy: 'Your recording and transcript are saved.',
        recordingId: 'r_1',
      ),
    );

    expect(find.text('Open the transcript'), findsOneWidget,
        reason: 'a model failure must never look like a lost recording');
  });

  testWidgets('an error with no recording offers no dead-end button', (tester) async {
    await pump(tester, const RecordError('Nothing was recorded.'));
    expect(find.text('Open the transcript'), findsNothing);
  });

  group('duration formatting', () {
    test('drops the hour until it is needed', () {
      expect(formatDuration(const Duration(seconds: 7)), '00:07');
      expect(formatDuration(const Duration(minutes: 12, seconds: 3)), '12:03');
      expect(formatDuration(const Duration(hours: 1, minutes: 2, seconds: 5)),
          '1:02:05');
    });
  });

  group('waveform', () {
    testWidgets('draws without overflowing a narrow strip', (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: SizedBox(
            height: 60,
            width: 200,
            child: Waveform(levels: List.generate(500, (i) => (i % 10) / 10)),
          ),
        ),
      ));
      await tester.pump();

      expect(tester.takeException(), isNull);
    });

    testWidgets('an empty level list is not an error', (tester) async {
      await tester.pumpWidget(const MaterialApp(
        home: Scaffold(body: SizedBox(height: 60, child: Waveform(levels: []))),
      ));
      await tester.pump();

      expect(tester.takeException(), isNull);
    });
  });
}
