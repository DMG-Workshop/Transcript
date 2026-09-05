/// What a note cost to produce.
///
/// Users bringing their own key are spending their own money, and a BYOK app that hides
/// that is untrustworthy. Two rules follow from that, and both are deliberate:
///
/// 1. Token counts are always shown, because they are measured — the providers return
///    them on every response.
/// 2. A dollar figure is shown only where a rate is actually known. Guessing at a price
///    is worse than showing none: a wrong number is believed, and prices change without
///    warning. Anything not in [seeded] shows tokens only until the user enters their
///    own rate in settings.
class TokenRate {
  const TokenRate({
    required this.inputPerMillion,
    required this.outputPerMillion,
    required this.asOf,
    this.cachedInputPerMillion,
    this.source = RateSource.seeded,
  });

  /// US dollars per million tokens.
  final double inputPerMillion;
  final double outputPerMillion;

  /// Cache reads, where the provider prices them separately.
  final double? cachedInputPerMillion;

  /// When this rate was recorded. Surfaced in the UI so a stale figure is visibly stale
  /// rather than quietly wrong.
  final DateTime asOf;

  final RateSource source;

  double costFor({
    required int inputTokens,
    required int outputTokens,
    int cachedInputTokens = 0,
  }) {
    final fresh = inputTokens - cachedInputTokens;
    final cachedRate = cachedInputPerMillion ?? inputPerMillion;
    return (fresh * inputPerMillion +
            cachedInputTokens * cachedRate +
            outputTokens * outputPerMillion) /
        1000000;
  }
}

enum RateSource {
  /// Shipped with the app. Shown with an "as of" date and an approximate marker.
  seeded,

  /// Typed in by the user, and trusted over a seeded value.
  user,
}

/// Rates the app ships with.
///
/// Only entries that can be stated accurately are here. Everything else deliberately has
/// no rate: the UI shows measured token counts and offers to take the user's own figure,
/// rather than inventing one that will be believed.
class Pricing {
  const Pricing(this._rates);

  /// The rates the app ships with.
  Pricing.withSeededRates() : _rates = Map.of(seededRates);

  static final Map<String, TokenRate> seededRates = {
    'claude-opus-5': TokenRate(
      inputPerMillion: 5,
      outputPerMillion: 25,
      cachedInputPerMillion: 0.5,
      asOf: DateTime.utc(2026, 6, 24),
    ),
    'claude-sonnet-5': TokenRate(
      inputPerMillion: 2,
      outputPerMillion: 10,
      asOf: DateTime.utc(2026, 6, 24),
    ),
    'claude-haiku-4-5': TokenRate(
      inputPerMillion: 1,
      outputPerMillion: 5,
      asOf: DateTime.utc(2026, 6, 24),
    ),
  };

  final Map<String, TokenRate> _rates;

  /// The user's own rate for a model, replacing any seeded value.
  Pricing withUserRate(String model, TokenRate rate) =>
      Pricing({..._rates, model: rate});

  TokenRate? rateFor(String? model) => model == null ? null : _rates[model];

  bool knowsRate(String? model) => rateFor(model) != null;

  /// A running total for one recording.
  CostEstimate estimate({
    required String? model,
    required int inputTokens,
    required int outputTokens,
    int cachedInputTokens = 0,
  }) {
    final rate = rateFor(model);
    return CostEstimate(
      inputTokens: inputTokens,
      outputTokens: outputTokens,
      cachedInputTokens: cachedInputTokens,
      dollars: rate?.costFor(
        inputTokens: inputTokens,
        outputTokens: outputTokens,
        cachedInputTokens: cachedInputTokens,
      ),
      rateAsOf: rate?.asOf,
      rateSource: rate?.source,
    );
  }
}

class CostEstimate {
  const CostEstimate({
    required this.inputTokens,
    required this.outputTokens,
    this.cachedInputTokens = 0,
    this.dollars,
    this.rateAsOf,
    this.rateSource,
  });

  final int inputTokens;
  final int outputTokens;
  final int cachedInputTokens;

  /// Null when no rate is known for the model. The UI shows tokens instead of a number
  /// it cannot stand behind.
  final double? dollars;

  final DateTime? rateAsOf;
  final RateSource? rateSource;

  int get totalTokens => inputTokens + outputTokens;

  bool get hasPrice => dollars != null;

  /// A price the user should not read as exact. Sub-cent amounts are common for a single
  /// recording, so they are not rounded away to "$0.00".
  String get formattedDollars {
    final value = dollars;
    if (value == null) return '';
    if (value < 0.01) return '<\$0.01';
    return '≈\$${value.toStringAsFixed(2)}';
  }

  String get formattedTokens =>
      '${_compact(inputTokens)} in · ${_compact(outputTokens)} out';

  static String _compact(int n) =>
      n >= 1000 ? '${(n / 1000).toStringAsFixed(n >= 10000 ? 0 : 1)}k' : '$n';
}
