import 'package:flutter_test/flutter_test.dart';
import 'package:transcript_app/src/recording/interruption_policy.dart';

void main() {
  const policy = InterruptionPolicy();

  InterruptionAction whileRecording(AudioInterruption e) =>
      policy.decide(e, isRecording: true, isPaused: false);

  InterruptionAction whilePaused(AudioInterruption e) =>
      policy.decide(e, isRecording: false, isPaused: true);

  test('a phone call pauses rather than ending the recording', () {
    expect(whileRecording(AudioInterruption.began), InterruptionAction.pause);
  });

  test('when the call ends, recording resumes', () {
    expect(whilePaused(AudioInterruption.endedResumable), InterruptionAction.resume);
  });

  test('a second interruption while already paused changes nothing', () {
    expect(whilePaused(AudioInterruption.began), InterruptionAction.ignore);
  });

  test('a resume signal for a recording that never paused is ignored', () {
    expect(whileRecording(AudioInterruption.endedResumable),
        InterruptionAction.ignore,
        reason: 'resuming a recording the user paused deliberately would capture a '
            'conversation they stepped away from');
  });

  test('losing the session for good finalizes what was captured', () {
    expect(whileRecording(AudioInterruption.endedPermanent),
        InterruptionAction.finalize);
    expect(
        whilePaused(AudioInterruption.endedPermanent), InterruptionAction.finalize);
  });

  test('headphones disconnecting does not stop a meeting', () {
    expect(whileRecording(AudioInterruption.routeChanged), InterruptionAction.ignore,
        reason: 'losing a meeting to a flat pair of earbuds would be indefensible');
  });

  test('process termination saves whatever exists, paused or not', () {
    expect(whileRecording(AudioInterruption.processTerminating),
        InterruptionAction.finalize);
    expect(whilePaused(AudioInterruption.processTerminating),
        InterruptionAction.finalize);
  });

  test('nothing happens to events that arrive when not recording at all', () {
    for (final event in AudioInterruption.values) {
      expect(policy.decide(event, isRecording: false, isPaused: false),
          InterruptionAction.ignore);
    }
  });

  group('interruption windows', () {
    test('an open window measures against the current clock', () {
      const window =
          InterruptionWindow(startMs: 30000, cause: AudioInterruption.began);
      expect(window.isOpen, isTrue);
      expect(window.durationMs(95000), 65000);
    });

    test('closing a window fixes its duration', () {
      const window =
          InterruptionWindow(startMs: 30000, cause: AudioInterruption.began);
      final closed = window.closedAt(51000);

      expect(closed.isOpen, isFalse);
      expect(closed.durationMs(999999), 21000,
          reason: 'a closed window must not keep growing with the clock');
    });

    test('every cause has a label the user can understand', () {
      for (final cause in AudioInterruption.values) {
        final window = InterruptionWindow(startMs: 0, cause: cause);
        expect(window.label, isNotEmpty);
        expect(window.label, isNot(contains('_')),
            reason: 'enum names are not user-facing copy');
      }
    });
  });
}
