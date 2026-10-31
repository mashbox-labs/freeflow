// FreeFlowEngine C shim. See include/ff_engine.h.
// Parakeet: same calls as whisper.cpp examples/parakeet-cli (greedy, segments joined with "\n" like -otxt).
// Audio LLM: same turns as llama.cpp tools/mtmd/mtmd-cli with -sys: the system turn and the user turn are
// tokenized and evaluated separately, ChatML text exactly as the GGUF's chat template renders it for LFM2.5/LFM3
// (checked against mtmd-cli's formatted_chat.prompt at b11982), greedy decoding (mtmd-cli --temp 0).
#include "ff_engine.h"

#include "llama.h"
#include "mtmd.h"
#include "mtmd-helper.h"
#include "parakeet.h"

#include <algorithm>
#include <atomic>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <mutex>
#include <string>
#include <utility>
#include <vector>

struct ff_engine {
    ff_engine_params p{};
    std::string      model_path, mmproj_path, system_prompt;
    std::string      text;
    parakeet_context * pk    = nullptr;
    llama_model      * model = nullptr;
    llama_context    * lctx  = nullptr;
    mtmd_context     * mctx  = nullptr;
    llama_sampler    * smpl  = nullptr;
    int32_t            sample_rate = 16000;
};

static std::atomic<bool> g_logging{true};

static void ff_log(enum ggml_log_level level, const char * text, void * /*user*/) {
    if (g_logging || level == GGML_LOG_LEVEL_ERROR) {
        fputs(text, stderr);
    }
}

static void ff_install_logs() {
    static std::once_flag once;
    std::call_once(once, [] {
        llama_log_set(ff_log, nullptr);
        mtmd_helper_log_set(ff_log, nullptr);
        parakeet_log_set(ff_log, nullptr);
        llama_backend_init();
    });
}

extern "C" {

ff_engine_params ff_engine_default_params(void) {
    ff_engine_params p{};
    p.kind       = FF_KIND_PARAKEET;
    p.use_gpu    = 0;
    p.n_threads  = 4;
    p.n_ctx      = 4096;
    p.max_tokens = 0;
    return p;
}

void ff_engine_set_logging(int32_t enabled) { g_logging = enabled != 0; }

const char * ff_engine_system_info(void) { return llama_print_system_info(); }

int32_t ff_engine_sample_rate(const ff_engine * e) { return e ? e->sample_rate : 0; }

void ff_engine_free(ff_engine * e) {
    if (!e) return;
    if (e->smpl)  llama_sampler_free(e->smpl);
    if (e->mctx)  mtmd_free(e->mctx);
    if (e->lctx)  llama_free(e->lctx);
    if (e->model) llama_model_free(e->model);
    if (e->pk)    parakeet_free(e->pk);
    delete e;
}

ff_engine * ff_engine_load(const ff_engine_params * pp, char * err, size_t err_len) {
    auto fail = [&](ff_engine * e, const char * msg) -> ff_engine * {
        if (err && err_len) snprintf(err, err_len, "%s", msg);
        ff_engine_free(e);
        return nullptr;
    };
    if (!pp || !pp->model_path) return fail(nullptr, "no model path");
    ff_install_logs();

    ff_engine * e = new ff_engine();
    e->p = *pp;
    e->model_path = pp->model_path;
    if (e->p.n_threads  <= 0) e->p.n_threads  = 4;
    if (e->p.n_ctx      <= 0) e->p.n_ctx      = 4096;

    if (pp->kind == FF_KIND_PARAKEET) {
        parakeet_context_params cp = parakeet_context_default_params();
        cp.use_gpu    = pp->use_gpu != 0;
        cp.gpu_device = 0;
        e->pk = parakeet_init_from_file_with_params(e->model_path.c_str(), cp);
        if (!e->pk) return fail(e, "parakeet: could not load the model");
        return e;
    }
    if (pp->kind != FF_KIND_AUDIO_LLM) return fail(e, "unknown model kind");
    if (!pp->mmproj_path)   return fail(e, "audio LLM needs its audio projector file");
    e->mmproj_path   = pp->mmproj_path;
    e->system_prompt = pp->system_prompt ? pp->system_prompt : "Perform ASR.";

    // CPU mode lists no devices at all, so nothing is ever sent to Metal (iOS refuses GPU work in the background).
    static ggml_backend_dev_t no_devices[1] = { nullptr };
    llama_model_params mp = llama_model_default_params();
    mp.n_gpu_layers = pp->use_gpu ? 999 : 0;
    if (!pp->use_gpu) mp.devices = no_devices;
    e->model = llama_model_load_from_file(e->model_path.c_str(), mp);
    if (!e->model) return fail(e, "llama: could not load the model");

    llama_context_params cp = llama_context_default_params();
    cp.n_ctx           = (uint32_t) e->p.n_ctx;
    cp.n_threads       = e->p.n_threads;
    cp.n_threads_batch = e->p.n_threads;
    cp.no_perf         = true;
    cp.offload_kqv     = pp->use_gpu != 0;
    cp.op_offload      = pp->use_gpu != 0;
    e->lctx = llama_init_from_model(e->model, cp);
    if (!e->lctx) return fail(e, "llama: could not create the context");

    mtmd_context_params mcp = mtmd_context_params_default();
    mcp.use_gpu       = pp->use_gpu != 0;
    mcp.n_threads     = e->p.n_threads;
    mcp.print_timings = false;
    e->mctx = mtmd_init_from_file(e->mmproj_path.c_str(), e->model, mcp);
    if (!e->mctx) return fail(e, "mtmd: could not load the audio projector");
    if (!mtmd_support_audio(e->mctx)) return fail(e, "mtmd: this projector has no audio input");
    e->sample_rate = mtmd_get_audio_sample_rate(e->mctx);
    e->smpl = llama_sampler_init_greedy();
    return e;
}

static int32_t eval_parts(ff_engine * e, const std::vector<mtmd_input_part> & parts, bool add_bos, llama_pos & n_past) {
    std::vector<const mtmd_input_part *> ptrs;
    for (const auto & p : parts) ptrs.push_back(&p);
    mtmd_input_chunks * chunks = mtmd_input_chunks_init();
    int32_t res = mtmd_tokenize_from_parts(e->mctx, chunks, ptrs.data(), ptrs.size(), add_bos);
    if (res != 0) { mtmd_input_chunks_free(chunks); return -3; }
    // Audio longer than the context: say so (-4) instead of a compute failure the caller would retry.
    if (n_past + mtmd_helper_get_n_pos(chunks) > (llama_pos) llama_n_ctx(e->lctx)) { mtmd_input_chunks_free(chunks); return -4; }
    llama_pos new_n_past = n_past;
    res = mtmd_helper_eval_chunks(e->mctx, e->lctx, chunks, n_past, 0, (int32_t) llama_n_batch(e->lctx), true, &new_n_past);
    mtmd_input_chunks_free(chunks);
    if (res != 0) return -2;
    n_past = new_n_past;
    return 0;
}

// Long recordings. These models are made for short clips: in one pass a long recording loses text (measured with
// 201 s of LibriSpeech on the Mac CLI: LFM3-Audio returned 80 of 541 words and ended normally; LFM2.5-Audio ran out of
// output room) or needs too much memory (Parakeet: 6.5 GB peak on 768 s). So audio longer than FF_WINDOW_S is cut into
// pieces at the quietest 100 ms between 2/3 of the window and its end, each piece is transcribed on its own (fresh
// context) and the texts are joined. A clip up to the window runs exactly as before.
static const double FF_WINDOW_S = 30.0;

static std::vector<std::pair<int32_t, int32_t>> ff_split(const float * pcm, int32_t n, int32_t sr) {
    std::vector<std::pair<int32_t, int32_t>> out;
    const int32_t win = (int32_t) (FF_WINDOW_S * sr), frame = sr / 10, step = sr / 20;
    int32_t start = 0;
    while (n - start > win) {
        // the last piece keeps at least 2 s, so no tiny tail is left for a model to guess at
        const int32_t lo = start + win * 2 / 3, hi = std::min(start + win - frame, n - 2 * sr - frame);
        int32_t best = hi;
        double best_e = -1;
        for (int32_t s = lo; s <= hi; s += step) {
            double en = 0;
            for (int32_t k = 0; k < frame; ++k) en += (double) pcm[s + k] * pcm[s + k];
            if (best_e < 0 || en < best_e) { best_e = en; best = s; }
        }
        const int32_t cut = best + frame / 2;   // the middle of the quietest 100 ms
        out.emplace_back(start, cut - start);
        start = cut;
    }
    out.emplace_back(start, n - start);
    return out;
}

static int32_t ff_piece(ff_engine * e, const float * pcm, int32_t n_samples, int32_t & n_out) {
    if (e->pk) {
        parakeet_full_params fp = parakeet_full_default_params(PARAKEET_SAMPLING_GREEDY);
        fp.n_threads = e->p.n_threads;
        if (parakeet_full(e->pk, fp, pcm, n_samples) != 0) return -2;
        const int n = parakeet_full_n_segments(e->pk);
        for (int i = 0; i < n; ++i) {
            e->text += parakeet_full_get_segment_text(e->pk, i);
            e->text += "\n";
        }
        n_out += n;
        return 0;
    }
    llama_memory_clear(llama_get_memory(e->lctx), true);
    llama_sampler_reset(e->smpl);
    llama_pos n_past = 0;

    const std::string sys_turn = "<|im_start|>system\n" + e->system_prompt + "<|im_end|>\n";
    const std::string user_pre = "\n<|im_start|>user\n";
    const std::string user_post = "<|im_end|>\n<|im_start|>assistant\n";
    mtmd_input_text t_sys  = { sys_turn.c_str(),  sys_turn.size(),  false, true };
    mtmd_input_text t_pre  = { user_pre.c_str(),  user_pre.size(),  false, true };
    mtmd_input_text t_post = { user_post.c_str(), user_post.size(), false, true };

    int32_t res = eval_parts(e, { { &t_sys, nullptr } }, true, n_past);
    if (res != 0) return res;

    mtmd_bitmap * audio = mtmd_bitmap_init_from_audio((size_t) n_samples, pcm);
    res = eval_parts(e, { { &t_pre, nullptr }, { nullptr, audio }, { &t_post, nullptr } }, false, n_past);
    mtmd_bitmap_free(audio);
    if (res != 0) return res;

    // Output cap from the audio length (speech is under ~7 tokens a second; 10 leaves room) within the context,
    // so a long dictation is never cut at a fixed count and a repeat loop on a short clip still stops. Reaching
    // the cap without an end token returns -4: the text would be incomplete, and it is never returned as if whole.
    if (!e->text.empty() && e->text.back() != ' ' && e->text.back() != '\n') e->text += ' ';
    const llama_vocab * vocab = llama_model_get_vocab(e->model);
    const int32_t room = (int32_t) llama_n_ctx(e->lctx) - (int32_t) n_past;
    int32_t cap = std::min<int32_t>(room, 64 + (int32_t) (10.0 * n_samples / e->sample_rate));
    if (e->p.max_tokens > 0) cap = std::min(cap, e->p.max_tokens);
    for (int32_t i = 0; i < cap; ++i) {
        llama_token tok = llama_sampler_sample(e->smpl, e->lctx, -1);
        if (llama_vocab_is_eog(vocab, tok)) return 0;
        // special = false: a control token never lands in the user's text.
        char buf[256];
        int n = llama_token_to_piece(vocab, tok, buf, sizeof(buf), 0, false);
        if (n < 0) {
            std::vector<char> big((size_t) -n);
            n = llama_token_to_piece(vocab, tok, big.data(), (int32_t) big.size(), 0, false);
            if (n > 0) e->text.append(big.data(), (size_t) n);
        } else {
            e->text.append(buf, (size_t) n);
        }
        ++n_out;
        llama_batch b = llama_batch_get_one(&tok, 1);
        const int32_t rc = llama_decode(e->lctx, b);
        if (rc == 1) return -4;   // no room left in the context
        if (rc != 0) return -2;
    }
    return -4;
}

int32_t ff_engine_transcribe(ff_engine * e, const float * pcm, int32_t n_samples, const char ** text, ff_timings * t) {
    if (!e || !pcm || n_samples <= 0 || !text) return -1;
    const auto t0 = std::chrono::steady_clock::now();
    e->text.clear();
    int32_t n_out = 0;
    for (const auto & piece : ff_split(pcm, n_samples, e->sample_rate)) {
        const int32_t res = ff_piece(e, pcm + piece.first, piece.second, n_out);
        if (res != 0) { e->text.clear(); return res; }   // never part of the text as if it were all of it
    }
    *text = e->text.c_str();
    if (t) {
        t->compute_ms = std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - t0).count();
        t->n_out = n_out;
    }
    return 0;
}

int32_t ff_engine_split(const float * pcm, int32_t n_samples, int32_t sample_rate, int32_t * starts, int32_t max_pieces) {
    if (!pcm || n_samples <= 0 || sample_rate <= 0) return 0;
    const auto pieces = ff_split(pcm, n_samples, sample_rate);
    for (size_t i = 0; starts && i < pieces.size() && (int32_t) i < max_pieces; ++i) starts[i] = pieces[i].first;
    return (int32_t) pieces.size();
}

void ff_free(void * p) { free(p); }

static uint32_t rd32(const unsigned char * b) { return b[0] | (b[1] << 8) | (b[2] << 16) | ((uint32_t) b[3] << 24); }
static uint16_t rd16(const unsigned char * b) { return (uint16_t) (b[0] | (b[1] << 8)); }

float * ff_wav_read(const char * path, int32_t * n_samples, int32_t * sample_rate, int32_t * channels) {
    FILE * f = path ? fopen(path, "rb") : nullptr;
    if (!f) return nullptr;
    std::vector<unsigned char> d;
    unsigned char buf[65536];
    size_t n;
    while ((n = fread(buf, 1, sizeof(buf), f)) > 0) d.insert(d.end(), buf, buf + n);
    fclose(f);
    if (d.size() < 12 || memcmp(d.data(), "RIFF", 4) != 0 || memcmp(d.data() + 8, "WAVE", 4) != 0) return nullptr;
    uint16_t fmt = 0, ch = 0, bits = 0;
    uint32_t sr = 0;
    size_t pos = 12;
    while (pos + 8 <= d.size()) {
        const unsigned char * c = d.data() + pos;
        uint32_t sz = rd32(c + 4);
        size_t body = pos + 8;
        if (body + sz > d.size()) sz = (uint32_t) (d.size() - body);
        if (memcmp(c, "fmt ", 4) == 0 && sz >= 16) {
            fmt = rd16(d.data() + body); ch = rd16(d.data() + body + 2); sr = rd32(d.data() + body + 4); bits = rd16(d.data() + body + 14);
            if (fmt == 0xFFFE && sz >= 26) fmt = rd16(d.data() + body + 24); // WAVE_FORMAT_EXTENSIBLE sub-format
        } else if (memcmp(c, "data", 4) == 0 && ch > 0) {
            const bool pcm16 = fmt == 1 && bits == 16, f32 = fmt == 3 && bits == 32;
            if (!pcm16 && !f32) return nullptr;
            const size_t frames = sz / (ch * (bits / 8));
            float * out = (float *) malloc(sizeof(float) * (frames ? frames : 1));
            for (size_t i = 0; i < frames; ++i) {
                float acc = 0.0f;
                for (uint16_t k = 0; k < ch; ++k) {
                    const unsigned char * s = d.data() + body + (i * ch + k) * (bits / 8);
                    if (pcm16) acc += (float) (int16_t) rd16(s) / 32768.0f;
                    else { float v; memcpy(&v, s, 4); acc += v; }
                }
                out[i] = ch == 1 ? acc : acc / (float) ch;
            }
            if (n_samples) *n_samples = (int32_t) frames;
            if (sample_rate) *sample_rate = (int32_t) sr;
            if (channels) *channels = ch;
            return out;
        }
        pos = body + sz + (sz & 1);
    }
    return nullptr;
}

} // extern "C"

// ---- Writer (build 13) -------------------------------------------------------------------------------------------
// LFM3's chat template (the GGUF's tokenizer.chat_template) is Jinja that llama_chat_apply_template does not render, so
// the prompt is written here exactly as that template renders one system turn and one user turn with
// add_generation_prompt and enable_thinking=false (checked with jinja2 against LFM3-1.7B-QAD-Q4_0.gguf from
// LiquidAI/LFM3-1.7B-GGUF bad5729b, 2026-10-30):
//   <|startoftext|><|im_start|>system\n{system}<|im_end|>\n<|im_start|>user\n{user}<|im_end|>\n<|im_start|>assistant\n<think></think>
// The BOS is in the text, so tokenizing adds no special token of its own (parse_special = true reads the markers).
struct ff_writer {
    ff_writer_params p{};
    llama_model    * model = nullptr;
    llama_context  * lctx  = nullptr;
    llama_sampler  * smpl  = nullptr;
    std::string      text;
    // Time limit of the current ff_writer_generate_within call (limited = false outside a limited call).
    bool             limited = false;
    std::chrono::steady_clock::time_point deadline{};
};

// ggml asks this between graph nodes while the prompt is evaluated; true stops the evaluation (llama_decode returns 2).
static bool ff_writer_past_limit(void * data) {
    const ff_writer * w = (const ff_writer *) data;
    return w->limited && std::chrono::steady_clock::now() >= w->deadline;
}

extern "C" {

ff_writer_params ff_writer_default_params(void) {
    ff_writer_params p{};
    p.use_gpu   = 0;
    p.n_threads = 4;
    p.n_ctx     = 4096;
    p.temp      = 0.0f;
    p.top_k     = 50;
    p.repeat_penalty = 1.1f;
    p.seed      = 42;
    return p;
}

void ff_writer_free(ff_writer * w) {
    if (!w) return;
    if (w->smpl)  llama_sampler_free(w->smpl);
    if (w->lctx)  llama_free(w->lctx);
    if (w->model) llama_model_free(w->model);
    delete w;
}

ff_writer * ff_writer_load(const ff_writer_params * pp, char * err, size_t err_len) {
    auto fail = [&](ff_writer * w, const char * msg) -> ff_writer * {
        if (err && err_len) snprintf(err, err_len, "%s", msg);
        ff_writer_free(w);
        return nullptr;
    };
    if (!pp || !pp->model_path) return fail(nullptr, "no model path");
    ff_install_logs();
    ff_writer * w = new ff_writer();
    w->p = *pp;
    if (w->p.n_threads <= 0) w->p.n_threads = 4;
    if (w->p.n_ctx     <= 0) w->p.n_ctx     = 4096;

    // CPU mode lists no devices at all, so nothing is ever sent to Metal (iOS refuses GPU work in the background).
    static ggml_backend_dev_t no_devices[1] = { nullptr };
    llama_model_params mp = llama_model_default_params();
    mp.n_gpu_layers = pp->use_gpu ? 999 : 0;
    if (!pp->use_gpu) mp.devices = no_devices;
    w->model = llama_model_load_from_file(pp->model_path, mp);
    if (!w->model) return fail(w, "llama: could not load the writing model");

    llama_context_params cp = llama_context_default_params();
    cp.n_ctx           = (uint32_t) w->p.n_ctx;
    cp.n_batch         = (uint32_t) w->p.n_ctx;
    cp.n_threads       = w->p.n_threads;
    cp.n_threads_batch = w->p.n_threads;
    cp.no_perf         = true;
    cp.offload_kqv     = pp->use_gpu != 0;
    cp.op_offload      = pp->use_gpu != 0;
    cp.abort_callback      = ff_writer_past_limit;
    cp.abort_callback_data = w;
    w->lctx = llama_init_from_model(w->model, cp);
    if (!w->lctx) return fail(w, "llama: could not create the context");
    // Thinking stays off. The prompt closes an empty think block, but LFM3 can still open a new one ("<think>" is a
    // token it may emit; it then reasons until the cap), so "<think>" and "</think>" are never sampled.
    const llama_vocab * vocab = llama_model_get_vocab(w->model);
    const int32_t n_vocab = llama_vocab_n_tokens(vocab);
    w->smpl = llama_sampler_chain_init(llama_sampler_chain_default_params());
    llama_token think[4], close[4];
    if (llama_tokenize(vocab, "<think>", 7, think, 4, false, true) == 1 &&
        llama_tokenize(vocab, "</think>", 8, close, 4, false, true) == 1) {
        const llama_logit_bias ban[2] = { { think[0], -INFINITY }, { close[0], -INFINITY } };
        llama_sampler_chain_add(w->smpl, llama_sampler_init_logit_bias(n_vocab, 2, ban));
    } else {
        return fail(w, "writer: <think> or </think> is not one token in this model");
    }
    if (w->p.temp <= 0.0f) {
        llama_sampler_chain_add(w->smpl, llama_sampler_init_greedy());
    } else {
        // Only generated tokens reach the penalties (the transcript is never penalised for being copied).
        if (w->p.repeat_penalty > 0.0f && w->p.repeat_penalty != 1.0f)
            llama_sampler_chain_add(w->smpl, llama_sampler_init_penalties(n_vocab, 64, w->p.repeat_penalty, 0.0f, 0.0f));
        if (w->p.top_k > 0) llama_sampler_chain_add(w->smpl, llama_sampler_init_top_k(w->p.top_k));
        llama_sampler_chain_add(w->smpl, llama_sampler_init_temp(w->p.temp));
        llama_sampler_chain_add(w->smpl, llama_sampler_init_dist(w->p.seed));
    }
    return w;
}

int32_t ff_writer_generate(ff_writer * w, const char * system, const char * user, int32_t max_tokens,
                           const char ** text, ff_writer_timings * t) {
    return ff_writer_generate_within(w, system, user, max_tokens, 0, text, t);
}

int32_t ff_writer_generate_within(ff_writer * w, const char * system, const char * user, int32_t max_tokens,
                                  int32_t time_limit_ms, const char ** text, ff_writer_timings * t) {
    return ff_writer_generate_from(w, system, user, "", max_tokens, time_limit_ms, text, t);
}

int32_t ff_writer_generate_from(ff_writer * w, const char * system, const char * user, const char * start,
                                int32_t max_tokens, int32_t time_limit_ms, const char ** text, ff_writer_timings * t) {
    if (!w || !system || !user || !start || !text) return -1;
    struct limit_off { ff_writer * w; ~limit_off() { w->limited = false; } } off{w};
    w->limited  = time_limit_ms > 0;
    w->deadline = std::chrono::steady_clock::now() + std::chrono::milliseconds(time_limit_ms > 0 ? time_limit_ms : 0);
    if (t) *t = ff_writer_timings{};
    w->text.clear();
    llama_memory_clear(llama_get_memory(w->lctx), true);
    llama_sampler_reset(w->smpl);

    const std::string prompt = std::string("<|startoftext|><|im_start|>system\n") + system +
        "<|im_end|>\n<|im_start|>user\n" + user + "<|im_end|>\n<|im_start|>assistant\n<think></think>" + start;
    const llama_vocab * vocab = llama_model_get_vocab(w->model);
    const int32_t need = -llama_tokenize(vocab, prompt.c_str(), (int32_t) prompt.size(), nullptr, 0, false, true);
    if (need <= 0) return -3;
    std::vector<llama_token> toks((size_t) need);
    if (llama_tokenize(vocab, prompt.c_str(), (int32_t) prompt.size(), toks.data(), need, false, true) != need) return -3;
    if (t) t->n_prompt = need;
    const int32_t n_ctx = (int32_t) llama_n_ctx(w->lctx);
    if (need >= n_ctx) return -4;
    const int32_t n_user = -llama_tokenize(vocab, user, (int32_t) strlen(user), nullptr, 0, false, false);

    const auto t0 = std::chrono::steady_clock::now();
    int32_t rc = llama_decode(w->lctx, llama_batch_get_one(toks.data(), need));
    if (rc == 0) llama_synchronize(w->lctx);   // decode returns before Metal finishes; time the real prompt work
    const auto t1 = std::chrono::steady_clock::now();
    if (t) t->prompt_ms = std::chrono::duration<double, std::milli>(t1 - t0).count();
    if (rc == 2) return -5;
    if (rc != 0) return rc == 1 ? -4 : -2;

    int32_t cap = n_ctx - need;
    if (max_tokens > 0) cap = std::min(cap, max_tokens);
    cap = std::min(cap, std::max(n_user, 0) * 3 / 2 + 16);
    int32_t res = -4, n_out = 0;
    for (int32_t i = 0; i < cap; ++i) {
        if (ff_writer_past_limit(w)) { res = -5; break; }
        llama_token tok = llama_sampler_sample(w->smpl, w->lctx, -1);
        if (llama_vocab_is_eog(vocab, tok)) { res = 0; break; }
        // special = false: a control token never lands in the user's text.
        char buf[256];
        int n = llama_token_to_piece(vocab, tok, buf, sizeof(buf), 0, false);
        if (n < 0) {
            std::vector<char> big((size_t) -n);
            n = llama_token_to_piece(vocab, tok, big.data(), (int32_t) big.size(), 0, false);
            if (n > 0) w->text.append(big.data(), (size_t) n);
        } else {
            w->text.append(buf, (size_t) n);
        }
        ++n_out;
        rc = llama_decode(w->lctx, llama_batch_get_one(&tok, 1));
        if (rc != 0) { res = rc == 2 ? -5 : rc == 1 ? -4 : -2; break; }
    }
    if (t) {
        t->gen_ms = std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - t1).count();
        t->n_out  = n_out;
    }
    if (res != 0) { w->text.clear(); return res; }
    *text = w->text.c_str();
    return 0;
}

// ---- Vocab ----
}

struct ff_vocab {
    llama_model * model = nullptr;
    const llama_vocab * vocab = nullptr;
};

extern "C" {

void ff_vocab_free(ff_vocab * v) {
    if (!v) return;
    if (v->model) llama_model_free(v->model);
    delete v;
}

ff_vocab * ff_vocab_load(const char * path, char * err, size_t err_len) {
    if (!path) { if (err && err_len) snprintf(err, err_len, "no vocab path"); return nullptr; }
    ff_install_logs();
    static ggml_backend_dev_t no_devices[1] = { nullptr };
    llama_model_params mp = llama_model_default_params();
    mp.vocab_only   = true;
    mp.n_gpu_layers = 0;
    mp.devices      = no_devices;
    ff_vocab * v = new ff_vocab();
    v->model = llama_model_load_from_file(path, mp);
    if (!v->model) { if (err && err_len) snprintf(err, err_len, "llama: could not load the vocab"); ff_vocab_free(v); return nullptr; }
    v->vocab = llama_model_get_vocab(v->model);
    return v;
}

int32_t ff_vocab_tokenize(const ff_vocab * v, const char * text, int32_t * ids, int32_t cap) {
    if (!v || !text) return 0;
    const int32_t n = llama_tokenize(v->vocab, text, (int32_t) strlen(text), (llama_token *) ids, ids ? cap : 0, false, true);
    return n;
}

int32_t ff_vocab_piece(const ff_vocab * v, int32_t id, char * buf, int32_t cap) {
    if (!v) return 0;
    return llama_token_to_piece(v->vocab, (llama_token) id, buf, cap, 0, false);
}

int32_t ff_vocab_is_end(const ff_vocab * v, int32_t id) {
    return v && llama_vocab_is_eog(v->vocab, (llama_token) id) ? 1 : 0;
}

int32_t ff_vocab_token(const ff_vocab * v, const char * text) {
    if (!v || !text) return -1;
    llama_token t[4];
    return llama_tokenize(v->vocab, text, (int32_t) strlen(text), t, 4, false, true) == 1 ? (int32_t) t[0] : -1;
}

} // extern "C"
