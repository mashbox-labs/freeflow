// ffasr: Mac CLI over the FreeFlowEngine C shim (the same code the app and the simulator test run).
// usage: ffasr -k parakeet|llm -m MODEL [--mmproj F] [--sys "Perform ASR in English."] [-t N] [--gpu] -o OUTDIR WAV...
// Writes OUTDIR/<name>.txt per file (raw engine text) and prints one summary line:
// files, audio_s, compute_s (sum of transcribe calls, load excluded), rtfx, load_s.
#include "ff_engine.h"

#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>

int main(int argc, char ** argv) {
    ff_engine_params p = ff_engine_default_params();
    std::string kind = "parakeet", model, mmproj, sys = "Perform ASR.", out = ".";
    std::vector<std::string> wavs;
    bool quiet = true;
    for (int i = 1; i < argc; ++i) {
        std::string a = argv[i];
        auto next = [&]() -> const char * { if (i + 1 >= argc) { fprintf(stderr, "missing value for %s\n", a.c_str()); exit(2); } return argv[++i]; };
        if      (a == "-k")       kind = next();
        else if (a == "-m")       model = next();
        else if (a == "--mmproj") mmproj = next();
        else if (a == "--sys")    sys = next();
        else if (a == "-t")       p.n_threads = atoi(next());
        else if (a == "-c")       p.n_ctx = atoi(next());
        else if (a == "-n")       p.max_tokens = atoi(next());
        else if (a == "--gpu")    p.use_gpu = 1;
        else if (a == "-o")       out = next();
        else if (a == "-v")       quiet = false;
        else                      wavs.push_back(a);
    }
    if (model.empty() || wavs.empty()) { fprintf(stderr, "usage: ffasr -k parakeet|llm -m MODEL [--mmproj F] [--sys S] [-t N] [--gpu] -o DIR WAV...\n"); return 2; }
    ff_engine_set_logging(quiet ? 0 : 1);
    p.kind = kind == "llm" ? FF_KIND_AUDIO_LLM : FF_KIND_PARAKEET;
    p.model_path = model.c_str();
    p.mmproj_path = mmproj.empty() ? nullptr : mmproj.c_str();
    p.system_prompt = sys.c_str();

    char err[512] = {0};
    const auto t0 = std::chrono::steady_clock::now();
    ff_engine * e = ff_engine_load(&p, err, sizeof(err));
    const double load_s = std::chrono::duration<double>(std::chrono::steady_clock::now() - t0).count();
    if (!e) { fprintf(stderr, "load failed: %s\n", err); return 1; }
    fprintf(stderr, "system_info: %s\n", ff_engine_system_info());

    double audio_s = 0, compute_s = 0;
    int ok = 0;
    for (const auto & w : wavs) {
        int32_t n = 0, sr = 0, ch = 0;
        float * pcm = ff_wav_read(w.c_str(), &n, &sr, &ch);
        if (!pcm || sr != ff_engine_sample_rate(e)) { fprintf(stderr, "skip %s (rate %d, want %d)\n", w.c_str(), sr, ff_engine_sample_rate(e)); ff_free(pcm); continue; }
        const char * text = nullptr;
        ff_timings t{};
        int32_t rc = ff_engine_transcribe(e, pcm, n, &text, &t);
        ff_free(pcm);
        if (rc != 0) { fprintf(stderr, "transcribe failed rc=%d %s\n", rc, w.c_str()); continue; }
        std::string base = w.substr(w.find_last_of('/') + 1);
        if (base.size() > 4 && base.compare(base.size() - 4, 4, ".wav") == 0) base.resize(base.size() - 4);
        FILE * f = fopen((out + "/" + base + ".txt").c_str(), "wb");
        if (f) { fputs(text, f); fclose(f); }
        audio_s += (double) n / sr;
        compute_s += t.compute_ms / 1000.0;
        ++ok;
        fprintf(stderr, "%s %.1f ms %d out\n", base.c_str(), t.compute_ms, t.n_out);
    }
    printf("ffasr kind %s files %d audio_s %.2f compute_s %.2f rtfx %.2f load_s %.3f threads %d gpu %d\n",
           kind.c_str(), ok, audio_s, compute_s, compute_s > 0 ? audio_s / compute_s : 0.0, load_s, p.n_threads, p.use_gpu);
    ff_engine_free(e);
    return ok == (int) wavs.size() ? 0 : 1;
}
