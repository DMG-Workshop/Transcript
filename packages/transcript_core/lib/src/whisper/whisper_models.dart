/// A downloadable whisper.cpp model.
///
/// The offline path's whole appeal is that nothing leaves the phone, but that costs disk:
/// a usable model is tens to hundreds of megabytes, and the user is entitled to choose
/// the trade rather than have a large download happen silently. The catalog exists so the
/// picker can state each model's size and rough quality before anything is fetched.
class WhisperModel {
  const WhisperModel({
    required this.id,
    required this.label,
    required this.approxBytes,
    required this.quality,
    required this.multilingual,
    required this.sha256,
  });

  final String id;
  final String label;

  /// Download size. Shown before the download starts, so a metered-connection user is
  /// not surprised.
  final int approxBytes;

  final WhisperQuality quality;

  /// English-only models are smaller and slightly better at English; the multilingual
  /// ones cover everything else. Naming the difference lets the user choose knowingly.
  final bool multilingual;

  /// Expected content hash. A model file that arrives corrupt would otherwise fail deep
  /// inside the native decoder with an error no user could act on.
  final String sha256;

  double get approxMegabytes => approxBytes / (1024 * 1024);

  /// ggml-org's canonical distribution path for a model id.
  String downloadPath() => 'ggml-org/whisper.cpp/resolve/main/ggml-$id.bin';
}

enum WhisperQuality {
  fastest('Fastest, least accurate'),
  balanced('A good balance'),
  best('Most accurate, slowest');

  const WhisperQuality(this.description);
  final String description;
}

/// The models the app offers to bundle.
///
/// Deliberately a short list: the point is a defensible default and one step in each
/// direction, not the full whisper zoo, which would only make the choice harder. Sizes
/// are the published ggml sizes; the hashes are placeholders to be filled from the real
/// artifacts before shipping, and [WhisperCatalog.verified] gates on that so an unset
/// hash can never reach a release build.
class WhisperCatalog {
  const WhisperCatalog._();

  static const String _unset = 'REPLACE_WITH_REAL_SHA256';

  static const List<WhisperModel> models = [
    WhisperModel(
      id: 'tiny',
      label: 'Tiny',
      approxBytes: 75 * 1024 * 1024,
      quality: WhisperQuality.fastest,
      multilingual: true,
      sha256: _unset,
    ),
    WhisperModel(
      id: 'base',
      label: 'Base',
      approxBytes: 142 * 1024 * 1024,
      quality: WhisperQuality.balanced,
      multilingual: true,
      sha256: _unset,
    ),
    WhisperModel(
      id: 'small',
      label: 'Small',
      approxBytes: 466 * 1024 * 1024,
      quality: WhisperQuality.best,
      multilingual: true,
      sha256: _unset,
    ),
  ];

  /// The default when the user has not chosen: base, because tiny is noticeably worse on
  /// real meetings and small is a big download to impose by default.
  static WhisperModel get recommended =>
      models.firstWhere((m) => m.id == 'base');

  static WhisperModel? byId(String id) {
    for (final model in models) {
      if (model.id == id) return model;
    }
    return null;
  }

  /// Whether every listed model has a real hash. A release build asserts this; a debug
  /// build may run with placeholders while the catalog is being finalised.
  static bool get verified => models.every((m) => m.sha256 != _unset);
}
