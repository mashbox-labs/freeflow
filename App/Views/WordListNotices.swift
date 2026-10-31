import FreeFlowKit
import SwiftUI

/// About > Word list notices: the licence and notice files of the lists the keyboard's autocorrect word list was built
/// from, read from the app bundle and shown exactly as shipped (ThirdParty/WordList, byte for byte as upstream
/// publishes them; their sha256 in ThirdParty/WordList/SHA256SUMS).
struct WordListNoticesView: View {
    struct Notice: Identifiable {
        let id: String       // file name in the bundle
        let title: String
        let source: String
    }

    static let notices: [Notice] = [
        Notice(id: "SymSpell-LICENSE", title: "SymSpell (Wolf Garbe)",
               source: "https://github.com/wolfgarbe/SymSpell/blob/6b8efd7d5053b68013e0193357a79011aa648ce2/LICENSE"),
        Notice(id: "symspellpy-LICENSE", title: "symspellpy 6.10.1 (mmb L)",
               source: "https://github.com/mammothb/symspellpy/blob/fb64aa0c32628e972801c8db83aa1cdd1afef2ac/LICENSE"),
        Notice(id: "GoogleBooksNgram-Usage.html", title: "Google Books Ngram data",
               source: "https://storage.googleapis.com/books/ngrams/books/datasetsv3.html"),
        Notice(id: "CC-BY-3.0-legalcode.txt", title: "Creative Commons Attribution 3.0 Unported",
               source: "https://creativecommons.org/licenses/by/3.0/legalcode.txt"),
        Notice(id: "SCOWL-Copyright", title: "Spell Checking Oriented Word Lists (SCOWL)",
               source: "https://github.com/en-wl/wordlist/blob/b22230cc5250887737fdefe9ca4c9d9d01230eaa/scowl/Copyright"),
        Notice(id: "FrequencyWords-README.md", title: "FrequencyWords (Hermit Dave): README",
               source: "https://github.com/hermitdave/FrequencyWords/blob/525f9b560de45753a5ea01069454e72e9aa541c6/README.md"),
        Notice(id: "FrequencyWords-LICENSE", title: "FrequencyWords (Hermit Dave): LICENSE",
               source: "https://github.com/hermitdave/FrequencyWords/blob/525f9b560de45753a5ea01069454e72e9aa541c6/LICENSE"),
        Notice(id: "CC-BY-SA-4.0-legalcode.txt", title: "Creative Commons Attribution-ShareAlike 4.0 International Public License",
               source: "https://creativecommons.org/licenses/by-sa/4.0/legalcode.txt"),
    ]

    /// Build 23: the first-prepare animation's notices (ThirdParty/LoaderArt, byte for byte).
    static let animationNotices: [Notice] = [
        Notice(id: "OFL-Outfit.txt", title: "Outfit font (first-run animation text)", source: "https://mashbox.gg/fonts/OFL-Outfit.txt"),
        Notice(id: "three.js-LICENSE", title: "three.js 0.170.0 (rendered the first-run animation's eagle)",
               source: "https://cdn.jsdelivr.net/npm/three@0.170.0/LICENSE"),
    ]

    /// Build 23: Conway Research's NOTICE for each Bark model, as published with its weights (ThirdParty/Models).
    static let modelNotices: [Notice] = [
        Notice(id: "Bark-3.0-Clean-NOTICE.txt", title: "Underdog Bark 3.0 Clean (Conway Research), CC-BY-4.0",
               source: "https://huggingface.co/FluidInference/bark-3.0-coreml/blob/73b0c0da665d29ea0332e9f0d32da8e26a4cdb38/bark-3.0-clean/NOTICE"),
        Notice(id: "Bark-3.0-Pro-NOTICE.txt", title: "Underdog Bark 3.0 Pro (Conway Research), CC-BY-4.0",
               source: "https://huggingface.co/ConwayResearch/Underdog-Bark-3.0-Pro/blob/4b5c51e04aa8d16dda9ecdff71bc29f7360149e4/coreml/NOTICE"),
    ]

    /// What Free Flow did with the lists (the keyboard's autocorrect-en.tsv).
    static let made = "The keyboard's autocorrect word list (autocorrect-en.tsv) is made from SymSpell's frequency_dictionary_en_82_765.txt, as packaged in symspellpy 6.10.1, and FrequencyWords' en_50k.txt (2018 lists): Free Flow keeps the words spelled with the letters a to z, turns each count into a natural-log share of its list, and keeps the higher value when both lists have a word. SymSpell made its list from Google Books Ngram data and SCOWL. The notices below are shown exactly as their authors publish them."

    static func text(_ name: String) -> String? {
        guard let url = Bundle.main.url(forResource: name, withExtension: nil) else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }

    var body: some View {
        Page {
            Text("THIRD-PARTY NOTICES").font(FFFont.display(34))
            Text(Self.made).font(FFFont.text(16)).foregroundStyle(Palette.muted)
            ForEach(Self.notices + Self.animationNotices + Self.modelNotices) { n in
                VStack(alignment: .leading, spacing: 6) {
                    Text(n.title).font(FFFont.text(17, .bold))
                    Text(n.source).font(FFFont.text(13)).foregroundStyle(Palette.faint).textSelection(.enabled)
                    Text(Self.text(n.id) ?? "Missing from this build: \(n.id)")
                        .font(.system(size: 12, design: .monospaced))
                        .textSelection(.enabled)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .ffCard()
                .accessibilityIdentifier("notice.\(n.id)")
            }
        }
        .navigationTitle("Third-party notices")
    }
}
