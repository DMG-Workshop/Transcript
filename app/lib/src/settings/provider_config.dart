import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:transcript_core/transcript_core.dart';

import '../net/dio_transport.dart';
import '../whisper/native_whisper_engine.dart';
import 'secure_key_store.dart';

/// Which providers exist to choose from, and which stage each can fill.
///
/// The two-slot split is enforced here rather than in the UI: an entry declares the
/// stages it supports, and the settings screen can only offer it where it fits. Claude
/// and the local servers simply never appear in the transcription list.
enum ProviderKind {
  onDeviceStt(
    id: 'on-device',
    label: 'On-device recognition',
    subtitle: 'Free, offline, no key. Audio never leaves the phone.',
    stages: {ProviderStage.transcription},
    needsKey: false,
    runsOnDevice: true,
  ),
  whisperOffline(
    id: 'whisper-offline',
    label: 'Whisper (offline)',
    subtitle: 'A downloaded model decodes on this device. No key, no network.',
    stages: {ProviderStage.transcription},
    needsKey: false,
    runsOnDevice: true,
  ),
  openAiWhisper(
    id: 'openai-transcribe',
    label: 'OpenAI Whisper',
    subtitle: 'Accurate, with word timestamps. 25 MB per request.',
    stages: {ProviderStage.transcription},
  ),
  geminiAudio(
    id: 'gemini-transcribe',
    label: 'Gemini (audio)',
    subtitle: 'Takes audio natively.',
    stages: {ProviderStage.transcription},
  ),
  anthropic(
    id: 'anthropic',
    label: 'Claude',
    subtitle: 'Structuring only — the API takes no audio.',
    stages: {ProviderStage.structuring},
  ),
  openAi(
    id: 'openai',
    label: 'OpenAI',
    subtitle: 'Structuring with strict JSON schema.',
    stages: {ProviderStage.structuring},
  ),
  gemini(
    id: 'gemini',
    label: 'Gemini',
    subtitle: 'Structuring with a response schema.',
    stages: {ProviderStage.structuring},
  ),
  ollama(
    id: 'ollama',
    label: 'Ollama',
    subtitle: 'A model on your own machine. No key, no cloud.',
    stages: {ProviderStage.structuring},
    needsKey: false,
    needsEndpoint: true,
    isLocalNetwork: true,
  ),
  lmStudio(
    id: 'lmstudio',
    label: 'LM Studio',
    subtitle: 'A model on your own machine. No key, no cloud.',
    stages: {ProviderStage.structuring},
    needsKey: false,
    needsEndpoint: true,
    isLocalNetwork: true,
  );

  const ProviderKind({
    required this.id,
    required this.label,
    required this.subtitle,
    required this.stages,
    this.needsKey = true,
    this.needsEndpoint = false,
    this.runsOnDevice = false,
    this.isLocalNetwork = false,
  });

  final String id;
  final String label;
  final String subtitle;
  final Set<ProviderStage> stages;
  final bool needsKey;

  /// True for the local servers, which are configured by address rather than by key.
  final bool needsEndpoint;

  /// Runs on the phone itself. Nothing leaves the device.
  final bool runsOnDevice;

  /// Runs on a machine the user owns. Nothing leaves their network.
  final bool isLocalNetwork;

  static List<ProviderKind> forStage(ProviderStage stage) =>
      values.where((k) => k.stages.contains(stage)).toList();
}

enum ProviderStage {
  transcription('Speech to text'),
  structuring('Notes and tasks');

  const ProviderStage(this.label);
  final String label;
}

/// What the user has chosen and typed. Secrets are not in here — only the fact that a
/// key exists. The key itself lives in [SecureKeyStore].
class ProviderSelection {
  const ProviderSelection({
    required this.kind,
    this.model,
    this.endpoint,
    this.hasKey = false,
  });

  final ProviderKind kind;
  final String? model;
  final String? endpoint;
  final bool hasKey;

  bool get isConfigured =>
      (!kind.needsKey || hasKey) && (!kind.needsEndpoint || endpoint != null);

  ProviderSelection copyWith({
    ProviderKind? kind,
    String? model,
    String? endpoint,
    bool? hasKey,
  }) =>
      ProviderSelection(
        kind: kind ?? this.kind,
        model: model ?? this.model,
        endpoint: endpoint ?? this.endpoint,
        hasKey: hasKey ?? this.hasKey,
      );
}

/// Builds a live provider from a selection. The one place that knows how to turn stored
/// settings into an adapter — the rest of the app talks to the interfaces.
class ProviderFactory {
  ProviderFactory(this._transport, this._keys, {WhisperEngine? whisperEngine})
      : _whisperEngine = whisperEngine ?? NativeWhisperEngine();

  final HttpTransport _transport;
  final KeyStore _keys;
  final WhisperEngine _whisperEngine;

  Future<StructuringProvider?> structuring(ProviderSelection selection) async {
    final key =
        selection.kind.needsKey ? await _keys.read(selection.kind.id) : null;
    if (selection.kind.needsKey && (key == null || key.isEmpty)) return null;

    return switch (selection.kind) {
      ProviderKind.anthropic => AnthropicStructuringProvider(
          transport: _transport,
          apiKey: key!,
          model: selection.model ?? AnthropicStructuringProvider.defaultModel,
        ),
      ProviderKind.openAi => OpenAiStructuringProvider(
          transport: _transport,
          apiKey: key!,
          model: selection.model ?? 'gpt-4o',
        ),
      ProviderKind.gemini => GeminiStructuringProvider(
          transport: _transport,
          apiKey: key!,
          model: selection.model ?? 'gemini-2.0-flash',
        ),
      ProviderKind.ollama || ProviderKind.lmStudio => LocalStructuringProvider(
          transport: _transport,
          baseUrl: Uri.parse(selection.endpoint!),
          model: selection.model ?? '',
          flavor: selection.kind == ProviderKind.ollama
              ? LocalFlavor.ollama
              : LocalFlavor.lmStudio,
          apiKey: key,
        ),
      _ => null,
    };
  }

  Future<TranscriptionProvider?> transcription(
      ProviderSelection selection) async {
    final key =
        selection.kind.needsKey ? await _keys.read(selection.kind.id) : null;
    if (selection.kind.needsKey && (key == null || key.isEmpty)) return null;

    return switch (selection.kind) {
      ProviderKind.openAiWhisper => OpenAiTranscriptionProvider(
          transport: _transport,
          apiKey: key!,
          model: selection.model ?? 'whisper-1',
        ),
      ProviderKind.geminiAudio => GeminiTranscriptionProvider(
          transport: _transport,
          apiKey: key!,
          model: selection.model ?? 'gemini-2.0-flash',
        ),
      ProviderKind.whisperOffline => WhisperTranscriptionProvider(
          engine: _whisperEngine,
          model: WhisperCatalog.byId(selection.model ?? '') ??
              WhisperCatalog.recommended,
        ),
      // On-device recognition is a platform channel, not an HTTP adapter — it arrives
      // in Phase 1 alongside the recorder.
      _ => null,
    };
  }
}

final transportProvider = Provider<HttpTransport>((ref) => DioTransport());

final keyStoreProvider = Provider<KeyStore>((ref) => const SecureKeyStore());

final providerFactoryProvider = Provider<ProviderFactory>(
  (ref) => ProviderFactory(
      ref.watch(transportProvider), ref.watch(keyStoreProvider)),
);

/// Persisted, non-secret settings.
class SettingsStore {
  const SettingsStore(this._prefs);

  final SharedPreferences _prefs;

  static const _kStructuring = 'provider.structuring';
  static const _kTranscription = 'provider.transcription';
  static const _kModelPrefix = 'provider.model.';
  static const _kEndpointPrefix = 'provider.endpoint.';

  ProviderKind? kindFor(ProviderStage stage) {
    final id = _prefs.getString(
        stage == ProviderStage.structuring ? _kStructuring : _kTranscription);
    if (id == null) return null;
    for (final kind in ProviderKind.values) {
      if (kind.id == id) return kind;
    }
    return null;
  }

  Future<void> setKind(ProviderStage stage, ProviderKind kind) =>
      _prefs.setString(
          stage == ProviderStage.structuring ? _kStructuring : _kTranscription,
          kind.id);

  String? modelFor(ProviderKind kind) =>
      _prefs.getString('$_kModelPrefix${kind.id}');
  Future<void> setModel(ProviderKind kind, String model) =>
      _prefs.setString('$_kModelPrefix${kind.id}', model);

  String? endpointFor(ProviderKind kind) =>
      _prefs.getString('$_kEndpointPrefix${kind.id}');
  Future<void> setEndpoint(ProviderKind kind, String endpoint) =>
      _prefs.setString('$_kEndpointPrefix${kind.id}', endpoint);

  /// The default pairing: nothing configured, nothing to pay for. On-device recognition
  /// needs no key, and a local model needs no key — so the app has something to do
  /// before the user has pasted anything.
  static const ProviderKind defaultTranscription = ProviderKind.onDeviceStt;

  /// What the current selection does with a recording.
  ///
  /// Computed from the same rules the running app uses, so settings and reality cannot
  /// disagree about where the audio goes.
  ConfigurationPosture get posture {
    final transcription =
        kindFor(ProviderStage.transcription) ?? defaultTranscription;
    final structuring = kindFor(ProviderStage.structuring);

    return ConfigurationPosture.from(
      transcriptionOnDevice: transcription.runsOnDevice,
      transcriptionLocalNetwork: transcription.isLocalNetwork,
      // Nothing chosen yet is treated as cloud rather than assumed private: an
      // unconfigured app must not display a privacy claim it has not earned.
      structuringOnDevice: structuring?.runsOnDevice ?? false,
      structuringLocalNetwork: structuring?.isLocalNetwork ?? false,
      needsApiKey: transcription.needsKey || (structuring?.needsKey ?? true),
    );
  }
}
