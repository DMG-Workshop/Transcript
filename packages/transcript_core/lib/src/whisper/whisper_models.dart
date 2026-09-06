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

  /// The canonical ggml distribution path for a model id: the same Hugging Face repo
  /// (`ggerganov/whisper.cpp`) that whisper.cpp's own `download-ggml-model.sh` pulls
  /// from. `ggml-org/whisper.cpp` looks like the same thing but 401s — there is no
  /// such gated repo serving these files, so that path silently never worked.
  String downloadPath() => 'ggerganov/whisper.cpp/resolve/main/ggml-$id.bin';
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
/// and hashes are the real published ggml artifacts, verified by downloading each one
/// and computing its SHA-256 directly — this repo's dev sandbox cannot reach Hugging
/// Face, so that ran as a one-off GitHub Actions job instead. [WhisperCatalog.verified]
/// still gates on every hash being set, so a future placeholder can never ship unnoticed.
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
      sha256:
          'be07e048e1e599ad46341c8d2a135645097a538221678b7acdd1b1919c6e1b21',
    ),
    WhisperModel(
      id: 'base',
      label: 'Base',
      approxBytes: 142 * 1024 * 1024,
      quality: WhisperQuality.balanced,
      multilingual: true,
      sha256:
          '60ed5bc3dd14eea856493d334349b405782ddcaf0028d4b5df4088345fba2efe',
    ),
    WhisperModel(
      id: 'small',
      label: 'Small',
      approxBytes: 466 * 1024 * 1024,
      quality: WhisperQuality.best,
      multilingual: true,
      sha256:
          '1be3a9b2063867b937e64e2ec7483364a79917e157fa98c5d94b5c1fffea987b',
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
