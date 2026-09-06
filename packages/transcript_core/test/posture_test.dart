import 'package:test/test.dart';
import 'package:transcript_core/transcript_core.dart';

class _Stub extends AiProvider {
  _Stub({required this.capabilities, this.local = false});

  @override
  final ProviderCapabilities capabilities;

  final bool local;

  @override
  bool get isLocalEndpoint => local;
  @override
  ProviderId get id => const ProviderId('stub');
  @override
  String get displayName => 'Stub';
  @override
  Future<ConnectionResult> test() async =>
      ConnectionResult.success(summary: 'ok');
}

void main() {
  final onDeviceStt = _Stub(
    capabilities: const ProviderCapabilities(
      acceptsAudio: true,
      acceptsText: false,
      nativeJsonSchema: false,
      requiresApiKey: false,
      runsOnDevice: true,
    ),
  );

  final cloudStt = _Stub(
    capabilities: const ProviderCapabilities(
      acceptsAudio: true,
      acceptsText: false,
      nativeJsonSchema: false,
    ),
  );

  final localLlm = _Stub(
    local: true,
    capabilities: const ProviderCapabilities(
      acceptsAudio: false,
      acceptsText: true,
      nativeJsonSchema: true,
      requiresApiKey: false,
    ),
  );

  final cloudLlm = _Stub(
    capabilities: const ProviderCapabilities(
      acceptsAudio: false,
      acceptsText: true,
      nativeJsonSchema: true,
    ),
  );

  final onDeviceLlm = _Stub(
    capabilities: const ProviderCapabilities(
      acceptsAudio: false,
      acceptsText: true,
      nativeJsonSchema: false,
      requiresApiKey: false,
      runsOnDevice: true,
    ),
  );

  test(
      'on-device recognition plus a local model keeps everything on the network',
      () {
    final posture = ConfigurationPosture.of(
      transcription: onDeviceStt,
      structuring: localLlm,
    );

    expect(posture.posture, DataPosture.localNetwork);
    expect(posture.needsApiKey, isFalse);
    expect(posture.summary, 'Nothing leaves your network');
  });

  test('a local-network setup does not claim to work in airplane mode', () {
    final posture = ConfigurationPosture.of(
      transcription: onDeviceStt,
      structuring: localLlm,
    );

    expect(posture.detail, contains('does not work in airplane mode'),
        reason: 'the phone still has to reach the machine running the model');
    expect(posture.needsInternet, isFalse,
        reason: 'no internet, but not no network');
  });

  test('only two on-device stages earn the airplane-mode claim', () {
    final posture = ConfigurationPosture.of(
      transcription: onDeviceStt,
      structuring: onDeviceLlm,
    );

    expect(posture.posture, DataPosture.onDevice);
    expect(posture.detail, contains('airplane mode'));
    expect(posture.needsInternet, isFalse);
  });

  test('cloud transcription names the recording as the thing that leaves', () {
    final posture =
        ConfigurationPosture.of(transcription: cloudStt, structuring: localLlm);

    expect(posture.posture, DataPosture.cloud);
    expect(posture.summary, contains('recording'));
    expect(posture.summary, isNot(contains('transcript')),
        reason: 'only the audio leaves in this configuration');
  });

  test('cloud structuring names the transcript, not the recording', () {
    final posture = ConfigurationPosture.of(
        transcription: onDeviceStt, structuring: cloudLlm);

    expect(posture.summary, contains('transcript'));
    expect(posture.summary, isNot(contains('recording')),
        reason: 'audio leaving is a bigger disclosure than text leaving');
  });

  test('both in the cloud names both', () {
    final posture =
        ConfigurationPosture.of(transcription: cloudStt, structuring: cloudLlm);

    expect(posture.summary, contains('recording'));
    expect(posture.summary, contains('transcript'));
    expect(posture.needsInternet, isTrue);
    expect(posture.needsApiKey, isTrue);
  });

  test('even the cloud posture states there is no backend in between', () {
    final posture =
        ConfigurationPosture.of(transcription: cloudStt, structuring: cloudLlm);
    expect(posture.detail, contains('never through our servers'));
  });

  test('the cloud posture says how to get back to a private one', () {
    final posture =
        ConfigurationPosture.of(transcription: cloudStt, structuring: cloudLlm);
    expect(posture.detail, contains('on-device recognition'));
  });
}
