/// What a provider can actually do.
///
/// Not decoration: this drives the settings UI (an option the provider cannot honour is
/// disabled, not silently ignored), the chunk sizer via [maxRequestBytes], and the
/// single-pass vs map/reduce decision via [contextWindowTokens]. Adding a provider should
/// mean adding one adapter and one capability record — nothing else.
class ProviderCapabilities {
  const ProviderCapabilities({
    required this.acceptsAudio,
    required this.acceptsText,
    required this.nativeJsonSchema,
    this.diarization = false,
    this.wordTimestamps = false,
    this.streaming = false,
    this.requiresApiKey = true,
    this.runsOnDevice = false,
    this.maxRequestBytes = 0,
    this.contextWindowTokens = 0,
    this.maxOutputTokens = 0,
  });

  /// Can take audio in — the transcription stage. False for Anthropic, Ollama and
  /// LM Studio, which is the fact that forces two provider slots rather than one.
  final bool acceptsAudio;

  /// Can take text in — the structuring stage.
  final bool acceptsText;

  /// Has a first-class structured-output mode. When false, structuring falls back to
  /// prompt-and-repair, which is measurably less reliable.
  final bool nativeJsonSchema;

  final bool diarization;
  final bool wordTimestamps;
  final bool streaming;

  /// False for on-device recognition and bundled whisper.cpp — the configurations that
  /// let the app work before the user has pasted anything.
  final bool requiresApiKey;

  /// No audio or transcript leaves the device.
  final bool runsOnDevice;

  /// Hard per-request ceiling. Zero means unbounded/not applicable. This is what caps
  /// chunk size — OpenAI's 25 MB transcription limit is the binding constraint in practice.
  final int maxRequestBytes;

  /// Input context for the structuring stage. Zero means unknown, which for a local model
  /// means "ask the server" — see OpenAiCompatibleStructuringProvider.
  final int contextWindowTokens;

  final int maxOutputTokens;

  ProviderCapabilities copyWith({
    int? contextWindowTokens,
    int? maxOutputTokens,
    bool? nativeJsonSchema,
  }) =>
      ProviderCapabilities(
        acceptsAudio: acceptsAudio,
        acceptsText: acceptsText,
        nativeJsonSchema: nativeJsonSchema ?? this.nativeJsonSchema,
        diarization: diarization,
        wordTimestamps: wordTimestamps,
        streaming: streaming,
        requiresApiKey: requiresApiKey,
        runsOnDevice: runsOnDevice,
        maxRequestBytes: maxRequestBytes,
        contextWindowTokens: contextWindowTokens ?? this.contextWindowTokens,
        maxOutputTokens: maxOutputTokens ?? this.maxOutputTokens,
      );
}
