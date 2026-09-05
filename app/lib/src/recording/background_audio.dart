import 'dart:async';
import 'dart:io';

import 'package:audio_session/audio_session.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';

import 'interruption_policy.dart';

/// Keeps a recording alive when the app is not in front, and reports when the OS takes
/// the microphone away.
///
/// The highest-risk platform work in the app, and the one failure users will not forgive:
/// a meeting that stopped recording when the screen locked is worse than never having
/// started. iOS needs the audio background mode and a correctly configured
/// `AVAudioSession`; Android needs a foreground service whose `microphone` type is
/// declared in the manifest and justified at review.
class BackgroundAudio {
  BackgroundAudio({AudioSession? session}) : _session = session;

  AudioSession? _session;
  StreamSubscription<AudioInterruptionEvent>? _interruptions;
  StreamSubscription<void>? _noisy;

  final _events = StreamController<AudioInterruption>.broadcast();

  /// Interruptions as the app understands them, already translated out of platform
  /// vocabulary. Feed these to [InterruptionPolicy].
  Stream<AudioInterruption> get interruptions => _events.stream;

  /// Configures the audio session for recording that survives the lock screen.
  Future<void> prepare() async {
    final session = _session ??= await AudioSession.instance;

    await session.configure(AudioSessionConfiguration(
      avAudioSessionCategory: AVAudioSessionCategory.playAndRecord,
      // allowBluetooth so a headset mic works; defaultToSpeaker so playback afterwards
      // is not trapped in the earpiece; mixWithOthers so a recording is not silenced by
      // whatever else is making noise.
      avAudioSessionCategoryOptions: AVAudioSessionCategoryOptions.allowBluetooth |
          AVAudioSessionCategoryOptions.defaultToSpeaker |
          AVAudioSessionCategoryOptions.mixWithOthers,
      avAudioSessionMode: AVAudioSessionMode.spokenAudio,
      androidAudioAttributes: const AndroidAudioAttributes(
        contentType: AndroidAudioContentType.speech,
        usage: AndroidAudioUsage.voiceCommunication,
      ),
      androidAudioFocusGainType: AndroidAudioFocusGainType.gain,
      androidWillPauseWhenDucked: false,
    ));

    _interruptions = session.interruptionEventStream.listen((event) {
      if (event.begin) {
        _events.add(AudioInterruption.began);
        return;
      }
      // `shouldResume` is the system telling us whether the session is ours again. A
      // pause and a permanent loss arrive through the same callback.
      _events.add(event.type == AudioInterruptionType.pause
          ? AudioInterruption.endedResumable
          : AudioInterruption.endedPermanent);
    });

    _noisy = session.becomingNoisyEventStream.listen((_) {
      _events.add(AudioInterruption.routeChanged);
    });
  }

  /// Claims the audio session and, on Android, starts the foreground service that keeps
  /// the process alive with the screen off.
  Future<void> startForeground({required String title}) async {
    await _session?.setActive(true);
    if (!Platform.isAndroid) return;

    FlutterForegroundTask.init(
      androidNotificationOptions: AndroidNotificationOptions(
        channelId: 'transcript_recording',
        channelName: 'Recording',
        channelDescription:
            'Shown while Transcript is recording, so the system does not stop it.',
        // Low importance: the notification has to exist for the service to run, but it
        // should not buzz during the meeting it is recording.
        channelImportance: NotificationChannelImportance.LOW,
        priority: NotificationPriority.LOW,
      ),
      iosNotificationOptions: const IOSNotificationOptions(),
      foregroundTaskOptions: ForegroundTaskOptions(
        eventAction: ForegroundTaskEventAction.repeat(30000),
        autoRunOnBoot: false,
        allowWakeLock: true,
        allowWifiLock: true,
      ),
    );

    await FlutterForegroundTask.startService(
      notificationTitle: title,
      notificationText: 'Tap to return to Transcript.',
    );
  }

  Future<void> stopForeground() async {
    if (Platform.isAndroid) await FlutterForegroundTask.stopService();
    // Release the session so music and calls behave normally again.
    await _session?.setActive(false);
  }

  Future<void> dispose() async {
    await _interruptions?.cancel();
    await _noisy?.cancel();
    await _events.close();
  }
}
