// FreeFlowEngine C shim: one ggml, two kinds of speech model.
//   FF_KIND_PARAKEET  : Parakeet TDT .bin through whisper.cpp's parakeet code
//   FF_KIND_AUDIO_LLM : Liquid LFM audio GGUF + audio projector through llama.cpp mtmd
// The Swift wrapper, the simulator test and the Mac CLI (Tools/ffasr.cpp) all call this file,
// so the same build flags give the same text everywhere.
#pragma once
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct ff_engine ff_engine;

enum ff_kind { FF_KIND_PARAKEET = 1, FF_KIND_AUDIO_LLM = 2 };

typedef struct ff_engine_params {
    int32_t      kind;          // enum ff_kind
    const char * model_path;    // Parakeet .bin or LLM .gguf
    const char * mmproj_path;   // audio projector .gguf (FF_KIND_AUDIO_LLM only)
    const char * system_prompt; // FF_KIND_AUDIO_LLM only, e.g. "Perform ASR in English."
    int32_t      use_gpu;       // 1 = Metal (foreground only on iOS), 0 = CPU only (no GPU work at all)
    int32_t      n_threads;     // CPU threads
    int32_t      n_ctx;         // FF_KIND_AUDIO_LLM context length (default 4096)
    int32_t      max_tokens;    // FF_KIND_AUDIO_LLM extra output cap (default 0 = from the audio length: 64 + 10 a second)
} ff_engine_params;

typedef struct ff_timings {
    double  compute_ms; // wall time of the transcribe call
    int32_t n_out;      // output tokens (LLM) or segments (Parakeet)
} ff_timings;

ff_engine_params ff_engine_default_params(void);

// NULL on failure, with a message in err.
ff_engine * ff_engine_load(const ff_engine_params * params, char * err, size_t err_len);

// 16 kHz mono float PCM in, any length: audio over 30 s is transcribed in pieces cut at quiet points and joined.
// Returns 0 and sets *text (UTF-8, owned by the engine, valid until the next call),
// -1 bad arguments, -2 compute failed (for example GPU work refused in the background), -3 tokenize failed,
// -4 too long for this model (the audio or its transcript does not fit the context; no partial text is returned).
int32_t ff_engine_transcribe(ff_engine * engine, const float * pcm, int32_t n_samples, const char ** text, ff_timings * timings);

void ff_engine_free(ff_engine * engine);

// Where ff_engine_transcribe cuts a long recording: writes up to max_pieces start samples and returns the number of
// pieces (each piece runs from its start to the next start or the end).
int32_t ff_engine_split(const float * pcm, int32_t n_samples, int32_t sample_rate, int32_t * starts, int32_t max_pieces);

int32_t      ff_engine_sample_rate(const ff_engine * engine); // input rate the model expects
const char * ff_engine_system_info(void);                     // ggml CPU features compiled in
void         ff_engine_set_logging(int32_t enabled);          // 0 = errors only

// 16-bit PCM or 32-bit float WAV reader shared by the CLI and the tests (int16 / 32768, like AVAudioFile and dr_wav).
// Returns samples (free with ff_free) or NULL; sets *n_samples, *sample_rate, *channels.
float * ff_wav_read(const char * path, int32_t * n_samples, int32_t * sample_rate, int32_t * channels);
void    ff_free(void * p);

// ---- Writer: a chat GGUF (LFM3-1.7B) that rewrites dictated text. Greedy, thinking off (build 13). ----
// Same backends as the speech models: use_gpu = 1 is Metal (foreground only on iOS), 0 lists no GPU device at all.
typedef struct ff_writer ff_writer;

typedef struct ff_writer_params {
    const char * model_path; // text GGUF that uses LFM3's chat turns
    int32_t      use_gpu;    // 1 = Metal, 0 = CPU only
    int32_t      n_threads;  // CPU threads (default 4)
    int32_t      n_ctx;      // context length (default 4096); the whole prompt is evaluated in one batch
    float        temp;       // 0 = greedy (default); > 0 = penalties -> top_k -> temp -> seeded draw (LiquidAI: 0.1, 50, 1.1)
    int32_t      top_k;      // used when temp > 0 (0 = off)
    float        repeat_penalty; // used when temp > 0, over the last 64 generated tokens (1 = off)
    uint32_t     seed;       // used when temp > 0; reset every call, so the same input gives the same text
} ff_writer_params;

typedef struct ff_writer_timings {
    double  prompt_ms; // evaluating the prompt
    double  gen_ms;    // generating the answer
    int32_t n_prompt;  // prompt tokens
    int32_t n_out;     // generated tokens (the end token is not counted)
} ff_writer_timings;

ff_writer_params ff_writer_default_params(void);

// NULL on failure, with a message in err.
ff_writer * ff_writer_load(const ff_writer_params * params, char * err, size_t err_len);

// One system turn and one user turn, greedy. The answer may be at most 1.5x the user turn's tokens + 16, and at most
// max_tokens (0 = no extra cap) and what the context leaves: a rewrite is never much longer than what was said, so a
// backend that never produces the end token stops early instead of running on.
// Returns 0 and sets *text (UTF-8, owned by the writer, valid until the next call); -1 bad arguments, -2 compute failed
// (for example GPU work refused in the background), -3 tokenize failed, -4 no end token within that length
// (no partial text is returned). Timings are filled in as far as the call got.
int32_t ff_writer_generate(ff_writer * writer, const char * system, const char * user, int32_t max_tokens,
                           const char ** text, ff_writer_timings * timings);

// The same with a time limit in milliseconds (0 = none), checked while the prompt is evaluated and before every token:
// past it the call stops and returns -5 (no partial text), so a slow or wrong backend can never hold a dictation.
int32_t ff_writer_generate_within(ff_writer * writer, const char * system, const char * user, int32_t max_tokens,
                                  int32_t time_limit_ms, const char ** text, ff_writer_timings * timings);

// The same with the answer turn opened by `start` (for example the label the system prompt's examples put before the
// written text), so what the model writes after it is the answer itself. `start` is not part of *text. "" = none.
int32_t ff_writer_generate_from(ff_writer * writer, const char * system, const char * user, const char * start,
                                int32_t max_tokens, int32_t time_limit_ms, const char ** text, ff_writer_timings * timings);

void ff_writer_free(ff_writer * writer);

// ---- Vocab: a model's tokenizer alone (llama.cpp, vocab-only load: no weights), for writers that run elsewhere
// (the Core ML LFM3 on the Neural Engine). Same tokenizer code as ff_writer, so the same text gives the same ids. ----
typedef struct ff_vocab ff_vocab;

// NULL on failure, with a message in err. `path` is a GGUF; only its metadata is read.
ff_vocab * ff_vocab_load(const char * path, char * err, size_t err_len);

// Chat-turn markers in `text` are parsed as their single tokens; nothing is added at the start. Returns the token
// count, or minus the count needed when it is larger than `cap` (nothing written then), or 0 on failure.
int32_t ff_vocab_tokenize(const ff_vocab * vocab, const char * text, int32_t * ids, int32_t cap);

// The text of one token (a control token gives ""), written to buf (not NUL-terminated). Returns the bytes written,
// or minus the bytes needed when cap is too small.
int32_t ff_vocab_piece(const ff_vocab * vocab, int32_t id, char * buf, int32_t cap);

// 1 when the token ends a turn (end of text or <|im_end|>).
int32_t ff_vocab_is_end(const ff_vocab * vocab, int32_t id);

// The single token for `text` (for example "<think>"), or -1 when it is not exactly one token.
int32_t ff_vocab_token(const ff_vocab * vocab, const char * text);

void ff_vocab_free(ff_vocab * vocab);

#ifdef __cplusplus
}
#endif
