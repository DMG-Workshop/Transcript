import 'package:test/test.dart';
import 'package:transcript_core/transcript_core.dart';

void main() {
  final pricing = Pricing.withSeededRates();

  test('prices a note from measured token counts', () {
    final estimate = pricing.estimate(
      model: 'claude-opus-5',
      inputTokens: 40000,
      outputTokens: 4000,
    );

    // 40k in at $5/M plus 4k out at $25/M.
    expect(estimate.dollars, closeTo(0.2 + 0.1, 0.0001));
    expect(estimate.formattedDollars, '≈\$0.30');
  });

  test('cache reads are priced separately where the provider prices them so',
      () {
    final full = pricing.estimate(
      model: 'claude-opus-5',
      inputTokens: 40000,
      outputTokens: 1000,
    );
    final cached = pricing.estimate(
      model: 'claude-opus-5',
      inputTokens: 40000,
      outputTokens: 1000,
      cachedInputTokens: 30000,
    );

    expect(cached.dollars, lessThan(full.dollars!),
        reason: 'the system prompt and schema are identical across recordings');
  });

  test('an unknown model shows tokens and no price at all', () {
    final estimate = pricing.estimate(
      model: 'some-local-model:8b',
      inputTokens: 12000,
      outputTokens: 900,
    );

    expect(estimate.hasPrice, isFalse,
        reason:
            'a guessed price is believed, and prices change without warning');
    expect(estimate.formattedTokens, '12k in · 900 out');
  });

  test('a local model has no price because it has no per-token cost', () {
    expect(pricing.knowsRate('llama3.1:8b'), isFalse);
  });

  test('the user can supply their own rate, and it wins', () {
    final custom = pricing.withUserRate(
      'gpt-4o',
      TokenRate(
        inputPerMillion: 2.5,
        outputPerMillion: 10,
        asOf: DateTime.utc(2026, 9, 5),
        source: RateSource.user,
      ),
    );

    final estimate =
        custom.estimate(model: 'gpt-4o', inputTokens: 1000000, outputTokens: 0);
    expect(estimate.dollars, closeTo(2.5, 0.0001));
    expect(estimate.rateSource, RateSource.user);
  });

  test('every seeded rate carries the date it was recorded', () {
    for (final entry in Pricing.seededRates.entries) {
      expect(entry.value.asOf.year, greaterThan(2024),
          reason:
              '${entry.key} needs an as-of date so a stale rate looks stale');
      expect(entry.value.source, RateSource.seeded);
    }
  });

  test('a sub-cent recording is not rounded away to zero', () {
    final estimate = pricing.estimate(
      model: 'claude-haiku-4-5',
      inputTokens: 500,
      outputTokens: 100,
    );
    expect(estimate.formattedDollars, '<\$0.01',
        reason: '"\$0.00" reads as free, which it is not');
  });

  test('token totals are compact but never misleading', () {
    const small = CostEstimate(inputTokens: 940, outputTokens: 12);
    expect(small.formattedTokens, '940 in · 12 out');

    const large = CostEstimate(inputTokens: 128400, outputTokens: 4200);
    expect(large.formattedTokens, '128k in · 4.2k out');
    expect(large.totalTokens, 132600);
  });
}
