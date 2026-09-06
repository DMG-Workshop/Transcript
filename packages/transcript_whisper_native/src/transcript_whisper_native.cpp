#include "transcript_whisper_native.h"

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <mutex>
#include <string>
#include <vector>

#define DR_WAV_IMPLEMENTATION
#include "whisper_cpp/examples/dr_wav.h"

#include "whisper.h"

namespace {

// Keeps the most recently used model resident so a sequence of chunks from
// the same recording does not reload the model file (and its weights) on
// every single call.
std::mutex g_mutex;
std::string g_cached_model_path;
whisper_context *g_cached_ctx = nullptr;

whisper_context *GetOrLoadContext(const std::string &model_path) {
  if (g_cached_ctx != nullptr && g_cached_model_path == model_path) {
    return g_cached_ctx;
  }
  if (g_cached_ctx != nullptr) {
    whisper_free(g_cached_ctx);
    g_cached_ctx = nullptr;
    g_cached_model_path.clear();
  }

  whisper_context_params cparams = whisper_context_default_params();
  cparams.use_gpu = false;

  whisper_context *ctx =
      whisper_init_from_file_with_params(model_path.c_str(), cparams);
  if (ctx == nullptr) {
    return nullptr;
  }

  g_cached_ctx = ctx;
  g_cached_model_path = model_path;
  return ctx;
}

// Appends `s` to `out` as a JSON string body (without the surrounding
// quotes), escaping control characters and replacing any byte sequence that
// is not valid UTF-8 with '?' so the result is always well-formed JSON.
void AppendJsonEscaped(std::string &out, const std::string &s) {
  size_t i = 0;
  const size_t n = s.size();
  while (i < n) {
    const unsigned char c = static_cast<unsigned char>(s[i]);
    if (c == '"') {
      out += "\\\"";
      i++;
      continue;
    }
    if (c == '\\') {
      out += "\\\\";
      i++;
      continue;
    }
    if (c < 0x20) {
      char buf[8];
      std::snprintf(buf, sizeof(buf), "\\u%04x", c);
      out += buf;
      i++;
      continue;
    }

    int len = 0;
    if ((c & 0x80) == 0x00) {
      len = 1;
    } else if ((c & 0xE0) == 0xC0) {
      len = 2;
    } else if ((c & 0xF0) == 0xE0) {
      len = 3;
    } else if ((c & 0xF8) == 0xF0) {
      len = 4;
    }

    bool valid = len > 0 && i + static_cast<size_t>(len) <= n;
    for (int k = 1; valid && k < len; k++) {
      const unsigned char cc = static_cast<unsigned char>(s[i + k]);
      if ((cc & 0xC0) != 0x80) {
        valid = false;
      }
    }

    if (!valid) {
      out += '?';
      i++;
      continue;
    }

    out.append(s, i, static_cast<size_t>(len));
    i += static_cast<size_t>(len);
  }
}

char *DupCString(const std::string &s) {
  char *buf = static_cast<char *>(std::malloc(s.size() + 1));
  if (buf == nullptr) {
    return nullptr;
  }
  std::memcpy(buf, s.data(), s.size());
  buf[s.size()] = '\0';
  return buf;
}

char *ErrorResult(const std::string &message) {
  std::string out = "{\"segments\":[],\"error\":\"";
  AppendJsonEscaped(out, message);
  out += "\"}";
  return DupCString(out);
}

}  // namespace

extern "C" {

FFI_PLUGIN_EXPORT char *transcript_whisper_transcribe(const char *model_path,
                                                       const char *wav_path,
                                                       const char *language_hint,
                                                       int32_t threads) {
  if (model_path == nullptr || wav_path == nullptr) {
    return ErrorResult("model_path and wav_path are required");
  }

  std::lock_guard<std::mutex> lock(g_mutex);

  whisper_context *ctx = GetOrLoadContext(model_path);
  if (ctx == nullptr) {
    return ErrorResult("failed to load whisper model");
  }

  drwav wav;
  if (!drwav_init_file(&wav, wav_path, nullptr)) {
    return ErrorResult("failed to open WAV file");
  }
  if (wav.channels != 1 && wav.channels != 2) {
    drwav_uninit(&wav);
    return ErrorResult("WAV file must be mono or stereo");
  }
  if (wav.sampleRate != WHISPER_SAMPLE_RATE) {
    drwav_uninit(&wav);
    return ErrorResult("WAV file must be 16 kHz");
  }
  if (wav.bitsPerSample != 16) {
    drwav_uninit(&wav);
    return ErrorResult("WAV file must be 16-bit PCM");
  }

  const int n = static_cast<int>(wav.totalPCMFrameCount);
  std::vector<int16_t> pcm16(static_cast<size_t>(n) * wav.channels);
  drwav_read_pcm_frames_s16(&wav, n, pcm16.data());
  drwav_uninit(&wav);

  std::vector<float> pcmf32(n);
  if (wav.channels == 1) {
    for (int i = 0; i < n; i++) {
      pcmf32[i] = static_cast<float>(pcm16[i]) / 32768.0f;
    }
  } else {
    for (int i = 0; i < n; i++) {
      pcmf32[i] = static_cast<float>(pcm16[2 * i] + pcm16[2 * i + 1]) / 65536.0f;
    }
  }

  whisper_full_params wparams =
      whisper_full_default_params(WHISPER_SAMPLING_GREEDY);
  wparams.print_progress = false;
  wparams.print_special = false;
  wparams.print_realtime = false;
  wparams.print_timestamps = false;
  wparams.translate = false;
  wparams.no_context = true;
  wparams.n_threads = threads > 0 ? threads : 4;

  const std::string language =
      (language_hint != nullptr && std::strlen(language_hint) > 0)
          ? language_hint
          : "auto";
  wparams.language = language.c_str();

  if (whisper_full(ctx, wparams, pcmf32.data(), static_cast<int>(pcmf32.size())) != 0) {
    return ErrorResult("whisper_full failed");
  }

  std::string out = "{\"segments\":[";
  const int n_segments = whisper_full_n_segments(ctx);
  for (int i = 0; i < n_segments; i++) {
    const int64_t t0_cs = whisper_full_get_segment_t0(ctx, i);
    const int64_t t1_cs = whisper_full_get_segment_t1(ctx, i);
    const char *text = whisper_full_get_segment_text(ctx, i);

    if (i > 0) {
      out += ",";
    }
    out += "{\"start_ms\":";
    out += std::to_string(t0_cs * 10);
    out += ",\"end_ms\":";
    out += std::to_string(t1_cs * 10);
    out += ",\"text\":\"";
    AppendJsonEscaped(out, text != nullptr ? text : "");
    out += "\"}";
  }
  out += "],\"error\":null}";
  return DupCString(out);
}

FFI_PLUGIN_EXPORT void transcript_whisper_free_string(char *ptr) {
  std::free(ptr);
}

FFI_PLUGIN_EXPORT void transcript_whisper_release(void) {
  std::lock_guard<std::mutex> lock(g_mutex);
  if (g_cached_ctx != nullptr) {
    whisper_free(g_cached_ctx);
    g_cached_ctx = nullptr;
    g_cached_model_path.clear();
  }
}

FFI_PLUGIN_EXPORT const char *transcript_whisper_version(void) {
  return "transcript_whisper_native/1.0 (whisper.cpp 1.9.1)";
}

}  // extern "C"
