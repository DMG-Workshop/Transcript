/// Provider-agnostic core for Transcript.
///
/// Pure Dart with no runtime dependencies and no Flutter: every provider adapter, the
/// schema dialects, the chunk planner and the structuring pipeline are unit-testable
/// without a device, a network, or an API key.
library;

export 'src/audio/wav.dart';
export 'src/models/note_document.dart';
export 'src/pipeline/chunk_planner.dart';
export 'src/pipeline/json_extract.dart';
export 'src/pipeline/quote_verifier.dart';
export 'src/pipeline/recording_pipeline.dart';
export 'src/pipeline/structuring_pipeline.dart';
export 'src/pipeline/transcript.dart';
export 'src/prompts/structuring_prompts.dart';
export 'src/providers/adapters/anthropic.dart';
export 'src/providers/adapters/fake.dart';
export 'src/providers/adapters/gemini.dart';
export 'src/providers/adapters/local.dart';
export 'src/providers/adapters/openai.dart';
export 'src/providers/capabilities.dart';
export 'src/providers/connection.dart';
export 'src/providers/errors.dart';
export 'src/providers/http_transport.dart';
export 'src/providers/provider.dart';
export 'src/schema/dialects.dart';
export 'src/schema/note_schema.dart';
export 'src/schema/validator.dart';
