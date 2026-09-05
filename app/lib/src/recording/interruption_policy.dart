/// Things the OS does to a recording that the app did not ask for.
enum AudioInterruption {
  /// A phone call, Siri, an alarm. The microphone is taken away mid-sentence.
  began,

  /// The interruption ended and the system says the session may resume.
  endedResumable,

  /// The interruption ended but the system will not give the session back — another app
  /// took it for good.
  endedPermanent,

  /// Headphones or a Bluetooth mic went away. Recording continues on the built-in mic.
  routeChanged,

  /// The OS is reclaiming the process. Whatever is captured has to be saved now.
  processTerminating,
}

/// What to do about it.
enum InterruptionAction {
  /// Stop capturing but keep the recording open; the elapsed clock keeps running so the
  /// gap is visible in the timeline rather than silently closing up.
  pause,

  resume,

  /// Stop and run the pipeline on what was captured.
  finalize,

  /// Nothing to do — carry on recording.
  ignore,
}

/// How the app responds to being interrupted.
///
/// Written as a pure function of (event, state) so the awkward cases — a call arriving
/// while already paused, an interruption that never ends — are decided once and tested,
/// rather than being emergent behaviour of platform callbacks firing in an order nobody
/// predicted.
class InterruptionPolicy {
  const InterruptionPolicy();

  InterruptionAction decide(
    AudioInterruption event, {
    required bool isRecording,
    required bool isPaused,
  }) {
    if (event == AudioInterruption.processTerminating) {
      // Save whatever exists, even if paused: a partial meeting is worth far more than
      // nothing, and there is no second chance once the process goes.
      return isRecording || isPaused
          ? InterruptionAction.finalize
          : InterruptionAction.ignore;
    }

    if (!isRecording && !isPaused) return InterruptionAction.ignore;

    return switch (event) {
      AudioInterruption.began =>
        isPaused ? InterruptionAction.ignore : InterruptionAction.pause,

      // Only resume something this policy paused. Resuming a recording the user paused
      // deliberately would start capturing a conversation they stepped away from.
      AudioInterruption.endedResumable =>
        isPaused ? InterruptionAction.resume : InterruptionAction.ignore,

      // The session is gone for good; keeping the recording open would capture silence
      // and tell the user nothing.
      AudioInterruption.endedPermanent => InterruptionAction.finalize,

      // A route change is not a reason to stop. Losing a meeting because someone's
      // earbuds ran out of battery would be indefensible.
      AudioInterruption.routeChanged => InterruptionAction.ignore,

      AudioInterruption.processTerminating => InterruptionAction.finalize,
    };
  }
}

/// A stretch of a recording where the microphone was not ours.
///
/// Recorded so the transcript can say so explicitly. Closing the gap silently would make
/// a two-minute phone call look like two minutes of nobody speaking, and the model would
/// then structure a meeting that appears to have a hole in its logic.
class InterruptionWindow {
  const InterruptionWindow({required this.startMs, this.endMs, required this.cause});

  final int startMs;

  /// Null while the interruption is still going.
  final int? endMs;

  final AudioInterruption cause;

  bool get isOpen => endMs == null;

  int durationMs(int nowMs) => (endMs ?? nowMs) - startMs;

  InterruptionWindow closedAt(int ms) =>
      InterruptionWindow(startMs: startMs, endMs: ms, cause: cause);

  String get label => switch (cause) {
        AudioInterruption.began ||
        AudioInterruption.endedResumable =>
          'interrupted by another app',
        AudioInterruption.endedPermanent => 'the microphone was taken by another app',
        AudioInterruption.routeChanged => 'audio device changed',
        AudioInterruption.processTerminating => 'the app was closed',
      };
}
