import '../providers/provider.dart';

/// Where a recording actually goes, given how the app is currently configured.
enum DataPosture {
  /// Nothing leaves the phone. Only reachable when both stages run on-device, which
  /// today means on-device recognition and an on-device model.
  onDevice,

  /// Nothing leaves the user's own network. Audio or text reaches a machine they own,
  /// and no third party sees either.
  localNetwork,

  /// A third-party service receives audio, transcript text, or both.
  cloud,
}

/// A plain description of what the current configuration does with a recording.
///
/// Exists because "private" is the app's central claim and the claim is only true for
/// some configurations. Stating which one is in force — and refusing to overstate it —
/// is the difference between a privacy feature and privacy marketing.
class ConfigurationPosture {
  const ConfigurationPosture({
    required this.posture,
    required this.needsInternet,
    required this.needsApiKey,
    required this.summary,
    required this.detail,
  });

  final DataPosture posture;

  /// True when a request must leave the user's network.
  final bool needsInternet;

  final bool needsApiKey;

  /// One line for the settings header.
  final String summary;

  /// The honest expansion, including what this configuration does *not* give you.
  final String detail;

  /// From live providers.
  static ConfigurationPosture of({
    required AiProvider transcription,
    required AiProvider structuring,
  }) =>
      from(
        transcriptionOnDevice: transcription.capabilities.runsOnDevice,
        transcriptionLocalNetwork: transcription.isLocalEndpoint,
        structuringOnDevice: structuring.capabilities.runsOnDevice,
        structuringLocalNetwork: structuring.isLocalEndpoint,
        needsApiKey: transcription.capabilities.requiresApiKey ||
            structuring.capabilities.requiresApiKey,
      );

  /// From what the user has selected, before either provider has been built.
  ///
  /// Settings has to state the posture while a key is still being typed, so this takes
  /// the facts rather than the objects — and both entry points share one implementation,
  /// so the settings screen and the running app can never disagree about what happens to
  /// a recording.
  static ConfigurationPosture from({
    required bool transcriptionOnDevice,
    required bool transcriptionLocalNetwork,
    required bool structuringOnDevice,
    required bool structuringLocalNetwork,
    required bool needsApiKey,
  }) {
    final transcriptionLocal =
        transcriptionOnDevice || transcriptionLocalNetwork;
    final structuringLocal = structuringOnDevice || structuringLocalNetwork;
    final needsKey = needsApiKey;

    if (transcriptionOnDevice && structuringOnDevice) {
      return ConfigurationPosture(
        posture: DataPosture.onDevice,
        needsInternet: false,
        needsApiKey: needsKey,
        summary: 'Nothing leaves this phone',
        detail: 'Both steps run on the device. This works in airplane mode.',
      );
    }

    if (transcriptionLocal && structuringLocal) {
      return ConfigurationPosture(
        posture: DataPosture.localNetwork,
        needsInternet: false,
        needsApiKey: needsKey,
        summary: 'Nothing leaves your network',
        detail:
            'Recognition runs on this phone and notes are written by a model on '
            'your own machine. No third party sees the recording or the transcript. '
            'It still needs the two to be on the same network, so it does not work '
            'in airplane mode.',
      );
    }

    // Naming which half is in the cloud matters: audio leaving is a bigger disclosure
    // than text leaving, and the user is entitled to know which one they chose.
    final cloudStages = <String>[
      if (!transcriptionLocal) 'the recording',
      if (!structuringLocal) 'the transcript',
    ];

    return ConfigurationPosture(
      posture: DataPosture.cloud,
      needsInternet: true,
      needsApiKey: needsKey,
      summary: '${_capitalise(cloudStages.join(' and '))} '
          '${cloudStages.length == 1 ? 'is' : 'are'} sent to a service you chose',
      detail:
          'It goes straight from this device to that service — never through our '
          'servers, because there are none. To keep everything on your own network, '
          'choose on-device recognition and a model running on your own machine.',
    );
  }

  static String _capitalise(String value) =>
      value.isEmpty ? value : value[0].toUpperCase() + value.substring(1);
}
