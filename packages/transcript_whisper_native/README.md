# transcript_whisper_native

An FFI plugin that vendors [ggml/whisper.cpp](https://github.com/ggml-org/whisper.cpp)
(CPU backend only, MIT licensed) behind a small custom shim, exposed to Dart
via `dart:ffi`. This is what backs `transcript_core`'s `WhisperEngine` seam
for fully offline, on-device speech-to-text.

Deliberately does **not** depend on ffmpeg or any other re-encoding library:
the native reader expects 16 kHz mono 16-bit PCM WAV, which is exactly what
`transcript_core`'s own WAV builder produces, so callers pass audio straight
through.

## Layout

* `src/whisper_cpp/` — the vendored ggml/whisper.cpp source tree, copied
  verbatim (see its `LICENSE`). Only the CPU backend is present; there is no
  CUDA/Metal/Vulkan source to accidentally pull in.
* `src/transcript_whisper_native.{h,cpp}` — the shim: loads a model (keeping
  the most recently used one resident across calls), decodes a WAV file, and
  returns a small JSON string of segments. Exported symbols:
  `transcript_whisper_transcribe`, `transcript_whisper_free_string`,
  `transcript_whisper_release`, `transcript_whisper_version`.
* `src/CMakeLists.txt` — builds the vendored sources into a static library
  and the shim into the shared library Android/Linux/Windows load. iOS and
  macOS build the same sources through their podspecs instead (CocoaPods has
  no CMake step), with `HEADER_SEARCH_PATHS` pointed at the same vendored
  tree.
* `lib/transcript_whisper_native.dart` — the public Dart API
  (`transcribeWav`, `transcribeWavSync`, `releaseWhisperModel`,
  `whisperNativeVersion`), plus the ffigen-generated raw bindings.

## Testing against a real compiled library

Run `tool/build_native_test_lib.sh` (needs `cmake` and a C++ compiler) to
build the shared library for the host platform straight from
`src/CMakeLists.txt`, then `flutter test test/native_smoke_test.dart` loads
*that exact binary* via `dart:ffi` — not a mock — and exercises symbol
resolution, string marshaling, and the native error-JSON path. There is no
whisper model file available in CI or most dev machines (they are tens to
hundreds of megabytes and fetched at runtime), so these tests cover
everything short of a successful decode; a real end-to-end transcription is
a manual check with a downloaded model.

CI (`transcript_whisper_native` job) runs the same two steps on every push.
