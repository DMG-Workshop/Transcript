#ifndef TRANSCRIPT_WHISPER_NATIVE_H_
#define TRANSCRIPT_WHISPER_NATIVE_H_

#include <stdint.h>

#if _WIN32
#define FFI_PLUGIN_EXPORT __declspec(dllexport)
#else
#define FFI_PLUGIN_EXPORT __attribute__((visibility("default"))) __attribute__((used))
#endif

#ifdef __cplusplus
extern "C" {
#endif

// Transcribes a 16 kHz mono 16-bit PCM WAV file with a ggml/whisper.cpp
// model and returns a JSON string:
//   {"segments":[{"start_ms":0,"end_ms":1200,"text":"..."}],"error":null}
// or, on failure:
//   {"segments":[],"error":"message"}
//
// `language_hint` may be NULL or empty for auto-detection.
// `threads` <= 0 selects a reasonable default.
//
// The returned pointer is heap-allocated with malloc() and must be released
// by the caller via transcript_whisper_free_string().
FFI_PLUGIN_EXPORT char *transcript_whisper_transcribe(
    const char *model_path,
    const char *wav_path,
    const char *language_hint,
    int32_t threads);

// Frees a string previously returned by this library.
FFI_PLUGIN_EXPORT void transcript_whisper_free_string(char *ptr);

// Releases any cached model context, freeing its memory. Safe to call at
// any time, including when nothing is loaded.
FFI_PLUGIN_EXPORT void transcript_whisper_release(void);

// Returns a static, non-owned version string. Never returns NULL.
FFI_PLUGIN_EXPORT const char *transcript_whisper_version(void);

#ifdef __cplusplus
}
#endif

#endif  // TRANSCRIPT_WHISPER_NATIVE_H_
