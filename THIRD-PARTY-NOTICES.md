# Third-party notices

Free Flow itself is licensed under the PolyForm Noncommercial License 1.0.0 (see LICENSE). It includes or downloads
the following. Each keeps its own licence, recorded as published at the pinned version or revision below.

## Code included in the app

| Component | Version / pin | Licence | Where |
|---|---|---|---|
| FluidAudio (FluidInference) | v0.18.0, commit b6a8b391 | Apache-2.0 | Packages/FluidAudio (LICENSE and ThirdPartyLicenses/ inside) |
| WhisperKit and ArgmaxCore (Argmax, argmax-oss-swift) | v1.1.1 | MIT | Packages/WhisperKit (LICENSE inside) |
| Barlow Semi Condensed | from mashbox.gg | SIL Open Font License 1.1 | Packages/FreeFlowKit/Sources/FreeFlowKit/Resources/Fonts/OFL-Barlow.txt |
| Big Shoulders Display | from mashbox.gg | SIL Open Font License 1.1 | Packages/FreeFlowKit/Sources/FreeFlowKit/Resources/Fonts/OFL-BigShoulders.txt |
| Outfit | from the MASHBOX visual language v1 (mashbox.gg) | SIL Open Font License 1.1 | Packages/FreeFlowKit/Sources/FreeFlowKit/Resources/Fonts/OFL-Outfit.txt |
| Geist Mono (ASCII subset) | from the MASHBOX visual language v1 (mashbox.gg) | SIL Open Font License 1.1 | Packages/FreeFlowKit/Sources/FreeFlowKit/Resources/Fonts/OFL-Geist.txt |
| llama.cpp incl. ggml and mtmd (ggml-org) | b11982, commit 8a199ad31a7eb27d5a46a6b08026176d82bc9894 | MIT, "Copyright (c) 2023-2026 The ggml authors" | compiled into Packages/FreeFlowEngine/FreeFlowSpeech.xcframework by scripts/build-engine.sh (LICENSE in the pinned source) |
| whisper.cpp, Parakeet code (ggml-org) | commit 284029c07012d2000941a08d38a31ffb71f4734e | MIT, "Copyright (c) 2023-2026 The ggml authors" | same xcframework (LICENSE in the pinned source) |
| LobeHub Icons (model-maker logo images: NVIDIA, OpenAI, Hugging Face, GitHub) | @lobehub/icons-static-png 1.97.1 (package.json "license": "MIT"; repository lobehub/lobe-icons tag v1.97.1 LICENSE: MIT, Copyright (c) 2023 LobeHub), fetched 2026-10-29 by scripts/fetch-logos.py | MIT | App/Assets.xcassets/Logos |

The logos are trademarks of their owners. Free Flow shows them only on its own model and credits screens to say who made
each model and where its files come from. They are not used in the app icon, App Store screenshots or store text.

## Word lists included in the keyboard

The keyboard's autocorrect word list, ThirdParty/WordList/autocorrect-en.tsv (92,404 words, sha256
1ad1341a43f41c79e8b4ca80d9ce6081641bd0d19753dac6f2b96b4403dabaa7), is made from the two lists below by
scripts/make-wordlist.py: it keeps the words spelled with a-z only, turns each count into a natural-log share of its list,
and keeps the higher value when both lists have a word. The licence and notice files sit next to it, byte for byte as
upstream publishes them (sha256 in ThirdParty/WordList/SHA256SUMS), and ship in the keyboard and the app, where
About > Word list notices shows them.

| Component | Version / pin | Licence, as upstream states it | Where |
|---|---|---|---|
| SymSpell frequency_dictionary_en_82_765.txt (Wolf Garbe), as packaged in symspellpy (mmb L) | symspellpy v6.10.1, commit fb64aa0c32628e972801c8db83aa1cdd1afef2ac, file sha256 68e9dc81c7e73bd7310b57e516ecaea0d8b6387ff71344a57c04174650a407a7 | SymSpell: MIT License, "Copyright (c) 2018 Wolf Garbe" (wolfgarbe/SymSpell LICENSE at 6b8efd7d5053b68013e0193357a79011aa648ce2). symspellpy: MIT License | ThirdParty/WordList/SymSpell-LICENSE, symspellpy-LICENSE |
| Google Books Ngram data (Google), the word frequencies in SymSpell's list (SymSpell README) | datasets page fetched 2026-10-30, sha256 b2f66a50d5713f91e181c8b5f685e03c9ceda80c2ce9ab7d69083d69a0f4bf50; the notice is bytes 6666-6842 of it | "This compilation is licensed under a Creative Commons Attribution 3.0 Unported License." | ThirdParty/WordList/GoogleBooksNgram-Usage.html, CC-BY-3.0-legalcode.txt |
| Spell Checking Oriented Word Lists (SCOWL) (Kevin Atkinson), the vocabulary filter in SymSpell's list (SymSpell README) | en-wl/wordlist v1 branch, commit b22230cc5250887737fdefe9ca4c9d9d01230eaa, scowl/Copyright | "Copyright 2000-2018 by Kevin Atkinson" with the permission notice in that file | ThirdParty/WordList/SCOWL-Copyright |
| FrequencyWords en_50k.txt, 2018 lists from OpenSubtitles2018 (Hermit Dave) | commit 525f9b560de45753a5ea01069454e72e9aa541c6, content/2018/en/en_50k.txt, sha256 5351ff405b1126ef555791dd4d9798a48e3e9a501a9fc481a9da957752cfb458 | "MIT License for code. CC-by-sa-4.0 for content." (README); LICENSE: MIT License, "Copyright (c) 2016 Hermit Dave" | ThirdParty/WordList/FrequencyWords-README.md, FrequencyWords-LICENSE, CC-BY-SA-4.0-legalcode.txt |

SymSpell's README does not say which SCOWL release it used; its licence link (wordlist.aspell.net/scowl-readme) now
leads to the SCOWL v1 readme, whose copyright section is the v1 scowl/Copyright file shipped here. The Creative Commons
legal codes are the plain-text files creativecommons.org serves (fetched 2026-10-30).

## Models the app downloads (not bundled)

Pinned in App/Resources/model-manifest.json; every file is checked against its sha256 before use.

| Model | Repository @ revision | Licence |
|---|---|---|
| Parakeet Ultra (Moondream, from NVIDIA Parakeet TDT 0.6B v3), Core ML by FluidInference | FluidInference/parakeet-ultra-coreml @ 95eaa59a39 (full sha in manifest) | CC-BY-4.0 (model card) |
| Phonon-2 (Fermion Research, from NVIDIA Parakeet TDT 0.6B v3), Core ML by FluidInference | FluidInference/phonon-2-coreml @ 1702fc22e7 (full sha in manifest) | CC-BY-4.0 (model card) |
| Parakeet Redux (Moondream, from NVIDIA Parakeet TDT 0.6B v3), Core ML by FluidInference | FluidInference/parakeet-redux-coreml @ 8c5ef97a29 (full sha in manifest) | CC-BY-4.0 (model card) |
| Underdog Bark 3.0 Clean (Conway Research), Core ML by FluidInference | FluidInference/bark-3.0-coreml @ 73b0c0da66 (full sha in manifest), folder bark-3.0-clean | CC-BY-4.0 (model card); NOTICE downloaded with it and in ThirdParty/Models |
| Underdog Bark 3.0 Pro (Conway Research), Core ML by Conway Research | ConwayResearch/Underdog-Bark-3.0-Pro @ 4b5c51e04a (full sha in manifest), folder coreml | CC-BY-4.0 (model card); LICENSE and NOTICE downloaded with it, NOTICE in ThirdParty/Models |
| Parakeet TDT 0.6B v3 (NVIDIA), GGUF Q4_0 / Q4_K / Q8_0 by ggml-org (C++ backup) | ggml-org/parakeet-GGUF @ 35156454d1 (full sha in manifest) | Repository card: MIT. Weights: NVIDIA, CC-BY-4.0, "parakeet-tdt-0.6b-v3" |

Optional later (not in this build): Qwen3.5-0.8B for on-device cleanup, Apache-2.0.
