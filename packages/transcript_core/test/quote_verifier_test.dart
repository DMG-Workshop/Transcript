import 'package:test/test.dart';
import 'package:transcript_core/transcript_core.dart';

import 'fixtures.dart';

void main() {
  final verifier = QuoteVerifier(fixtureTranscript);

  test('an exact quote verifies', () {
    expect(
        verifier
            .verify('we need to get off the legacy session store')
            .isVerified,
        isTrue);
  });

  test('casing, punctuation and smart quotes do not matter', () {
    expect(
      verifier
          .verify('It CANNOT handle the load — we are expecting…')
          .isVerified,
      isTrue,
    );
  });

  test('a dropped filler word still verifies', () {
    // The model quoted it without "can you", which models routinely do.
    expect(
      verifier
          .verify(
              'Priya take the migration, it has to be done by the eighteenth')
          .isVerified,
      isTrue,
    );
  });

  test('a fabricated quote is flagged', () {
    final verdict =
        verifier.verify('Dennis will handle the billing integration by Friday');
    expect(verdict, QuoteVerdict.missing);
    expect(verdict.shouldFlag, isTrue);
  });

  test('a plausible-sounding but unspoken quote is flagged', () {
    // The transcript discusses auth and launch; it never mentions load testing.
    expect(
      verifier
          .verify('we should run a full load test before we ship')
          .shouldFlag,
      isTrue,
    );
  });

  test('a too-short quote is neither trusted nor flagged', () {
    final verdict = verifier.verify('okay so');
    expect(verdict, QuoteVerdict.tooShort);
    expect(verdict.shouldFlag, isFalse,
        reason:
            'flagging unverifiable stubs would train users to ignore the badge');
  });

  test('an empty quote is flagged', () {
    expect(verifier.verify('').shouldFlag, isTrue);
  });

  test('words must appear in order, not merely be present', () {
    // Every word below occurs in the transcript, but not in this sequence.
    expect(
      verifier
          .verify('launch the eighteenth migration store session legacy')
          .shouldFlag,
      isTrue,
    );
  });
}
