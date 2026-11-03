#!/usr/bin/env python3
"""Pin each speech model to a Hugging Face commit and record sha256 + size for every file the app downloads.
LFS files: sha256 from the HF API (lfs.oid). Small non-LFS files: downloaded at the pinned commit and hashed.
Usage: scripts/make-manifest.py > App/Resources/model-manifest.json
       scripts/make-manifest.py --only id1,id2 > new.json   (those ids only, merged into the current manifest, others kept as they are)"""
import hashlib, json, sys, urllib.request, urllib.parse

WK = ("argmaxinc/whisperkit-coreml", "0f63a7800b00dd0226abd051b906c246e1907482")
MODELS = [
    # id, repo, revision (None = current main, then pinned), subfolder, top-level entries to keep (None = all)
    ("small", WK[0], WK[1], "openai_whisper-small_216MB", None),
    ("medium", "FluidInference/parakeet-tdt-0.6b-v3-coreml", "7dd20fe6b1", "", ["Preprocessor.mlmodelc", "Encoder.mlmodelc", "Decoder.mlmodelc", "JointDecisionv3.mlmodelc", "parakeet_vocab.json"]),
    ("large", WK[0], WK[1], "openai_whisper-large-v3-v20240930_turbo_632MB", None),
    ("small.tokenizer", "openai/whisper-small", None, "", ["tokenizer.json", "tokenizer_config.json"]),
    ("large.tokenizer", "openai/whisper-large-v3-turbo", None, "", ["tokenizer.json", "tokenizer_config.json"]),
    # More Whisper sizes and quantizations on the same WhisperKit Core ML commit: tiny and base in
    # 16-bit float, small in 16-bit float next to the 4-bit palettized small above. Tokenizers from OpenAI's repos.
    ("whisper-tiny", WK[0], WK[1], "openai_whisper-tiny", None),
    ("whisper-base", WK[0], WK[1], "openai_whisper-base", None),
    ("whisper-small-f16", WK[0], WK[1], "openai_whisper-small", None),
    ("whisper-tiny.tokenizer", "openai/whisper-tiny", None, "", ["tokenizer.json", "tokenizer_config.json"]),
    ("whisper-base.tokenizer", "openai/whisper-base", None, "", ["tokenizer.json", "tokenizer_config.json"]),
    ("whisper-small-f16.tokenizer", "openai/whisper-small", "973afd2496", "", ["tokenizer.json", "tokenizer_config.json"]),
    # Whisper back (build 26): distil-large-v3 (distil-whisper, English, 2 decoder layers) on the same WhisperKit Core ML
    # commit, its 594 MB build; tokenizer from distil-whisper's repo at a pinned commit.
    ("distil-large-v3", WK[0], WK[1], "distil-whisper_distil-large-v3_594MB", None),
    ("distil-large-v3.tokenizer", "distil-whisper/distil-large-v3", "8031d2e6ce6631b7fc45629dddfc00271116d981", "", ["tokenizer.json", "tokenizer_config.json"]),
    # C++ engine (FreeFlowEngine): ggml-org Parakeet v3 files for whisper.cpp's parakeet code, one weight type per file
    ("parakeet-gguf-q4_0", "ggml-org/parakeet-GGUF", "35156454", "", ["ggml-parakeet-tdt-0.6b-v3-q4_0.bin"]),
    ("parakeet-gguf-q4_k", "ggml-org/parakeet-GGUF", "35156454", "", ["ggml-parakeet-tdt-0.6b-v3-q4_k.bin"]),
    ("parakeet-gguf-q8_0", "ggml-org/parakeet-GGUF", "35156454", "", ["ggml-parakeet-tdt-0.6b-v3-q8_0.bin"]),
    # Build 23 catalog: the 2026 Parakeet-family Core ML builds, all on the v3 component
    # contract (Preprocessor, Encoder, Decoder, JointDecisionv3, parakeet_vocab.json). Phonon-2: only the default Encoder
    # (the 3-window ladder); the other encoder files in that repo are not downloaded.
    ("parakeet-ultra", "FluidInference/parakeet-ultra-coreml", "95eaa59a39d4394f047a4dc5cce480388a60d1b6", "", ["Preprocessor.mlmodelc", "Encoder.mlmodelc", "Decoder.mlmodelc", "JointDecisionv3.mlmodelc", "parakeet_vocab.json"]),
    ("phonon-2", "FluidInference/phonon-2-coreml", "1702fc22e76f203d5ca464cd5d3ef130a45ce2c0", "", ["Preprocessor.mlmodelc", "Encoder.mlmodelc", "Decoder.mlmodelc", "JointDecisionv3.mlmodelc", "parakeet_vocab.json"]),
    ("parakeet-redux", "FluidInference/parakeet-redux-coreml", "8c5ef97a29cd120dc76b354b3f22b7fec3b486f9", "", ["Preprocessor.mlmodelc", "Encoder.mlmodelc", "Decoder.mlmodelc", "JointDecisionv3.mlmodelc", "parakeet_vocab.json"]),
    # Build 23: Underdog Bark 3.0 Clean (Conway Research)
    ("bark-3.0-clean", "FluidInference/bark-3.0-coreml", "73b0c0da665d29ea0332e9f0d32da8e26a4cdb38", "bark-3.0-clean", ["Preprocessor.mlmodelc", "Encoder.mlmodelc", "Decoder.mlmodelc", "JointDecisionv3.mlmodelc", "parakeet_vocab.json", "NOTICE"]),
    # Build 23: Conway Research's own full Core ML build of Underdog Bark 3.0 Pro (fp16), as published:
    # the .mlpackage files are compiled once on the device (Transcriber.compilePackages); we host nothing
    ("bark-3-pro", "ConwayResearch/Underdog-Bark-3.0-Pro", "4b5c51e04aa8d16dda9ecdff71bc29f7360149e4", "coreml", None),
    # Liquid AI audio LLMs for llama.cpp mtmd: the model and its audio projector (mmproj) from the same commit
    ("lfm3-audio-q4_0", "LiquidAI/LFM3-Audio-2B-GGUF", "642697a5", "", ["LFM3-Audio-2B-Q4_0.gguf", "mmproj-LFM3-Audio-2B-Q8_0.gguf"]),
]
ONLY = None
if len(sys.argv) == 3 and sys.argv[1] == "--only":
    ONLY = set(sys.argv[2].split(","))
    MODELS = [m for m in MODELS if m[0] in ONLY]
    assert {m[0] for m in MODELS} == ONLY, "unknown id in --only"

def get(url):
    with urllib.request.urlopen(urllib.request.Request(url, headers={"User-Agent": "freeflow-manifest"}), timeout=120) as r:
        return r.read()

out = {}
if ONLY:
    from pathlib import Path
    out = json.loads((Path(__file__).resolve().parent.parent / "App/Resources/model-manifest.json").read_text())
for mid, repo, pin, sub, keep in MODELS:
    info = json.loads(get(f"https://huggingface.co/api/models/{repo}/revision/{pin}" if pin else f"https://huggingface.co/api/models/{repo}"))
    rev = info["sha"]
    tree = json.loads(get(f"https://huggingface.co/api/models/{repo}/tree/{rev}" + (f"/{sub}" if sub else "") + "?recursive=1"))
    files = {}
    for e in tree:
        if e["type"] != "file":
            continue
        rel = e["path"][len(sub) + 1:] if sub else e["path"]
        top = rel.split("/")[0]
        if keep is not None and top not in keep:
            continue
        if keep is None and (top.startswith(".") or top.lower() in ("readme.md", ".gitattributes")):
            continue
        if "lfs" in e:
            sha, size = e["lfs"]["oid"], e["lfs"]["size"]
        else:
            data = get(f"https://huggingface.co/{repo}/resolve/{rev}/{urllib.parse.quote(e['path'])}")
            sha, size = hashlib.sha256(data).hexdigest(), len(data)
        files[rel] = {"sha256": sha, "size": size}
    lic = (info.get("cardData") or {}).get("license")
    out[mid] = {"repo": repo, "subfolder": sub, "revision": rev, "license_tag": lic,
                "bytes": sum(f["size"] for f in files.values()), "files": dict(sorted(files.items()))}
    print(f"{mid}: {repo} @ {rev[:10]} license={lic} files={len(files)} MB={out[mid]['bytes']/1e6:.1f} top={sorted({k.split('/')[0] for k in files})}", file=sys.stderr)
json.dump(out, sys.stdout, indent=1, sort_keys=True)
