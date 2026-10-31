#!/usr/bin/env python3
"""Rebuilds the keyboard's autocorrect word list, ThirdParty/WordList/autocorrect-en.tsv, from the two pinned upstream
lists, and checks it and every licence and notice file in ThirdParty/WordList against SHA256SUMS. Build-time only: the
keyboard never downloads anything.

Sources (each checked against its sha256 before use):
- SymSpell frequency_dictionary_en_82_765.txt (Wolf Garbe; Google Books Ngram data + SCOWL), as packaged in
  symspellpy v6.10.1 (mmb L). SymSpell: MIT License. symspellpy: MIT License.
- FrequencyWords content/2018/en/en_50k.txt (Hermit Dave; OpenSubtitles2018). "MIT License for code. CC-by-sa-4.0 for
  content." (README)

The list: every word of either list spelled with a-z only, with the natural log of its count over its list's total;
a word in both keeps the higher value; sorted; one `word<TAB>value` per line with Python's repr of the float (it reads
back as the same double in Swift). This is exactly the list the build 10 autocorrect scores used (ac_proto.py merge).

The shipped bytes come from glibc's log (built on Linux with Python 3.12): macOS's libm rounds 9 of the
92,404 values one unit differently in the last place, so on a Mac the rebuild reports those lines instead of matching.

Usage: scripts/make-wordlist.py           rebuild in memory, compare with the shipped list, check SHA256SUMS
       scripts/make-wordlist.py --write   also write the rebuilt list (only when changing the list on purpose)
       scripts/make-wordlist.py --check   check ThirdParty/WordList against SHA256SUMS only (no download)"""
import hashlib
import io
import math
import re
import sys
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
DIR = ROOT / "ThirdParty/WordList"
LIST = DIR / "autocorrect-en.tsv"
SOURCES = [
    ("https://raw.githubusercontent.com/mammothb/symspellpy/fb64aa0c32628e972801c8db83aa1cdd1afef2ac/symspellpy/frequency_dictionary_en_82_765.txt",
     "68e9dc81c7e73bd7310b57e516ecaea0d8b6387ff71344a57c04174650a407a7"),
    ("https://raw.githubusercontent.com/hermitdave/FrequencyWords/525f9b560de45753a5ea01069454e72e9aa541c6/content/2018/en/en_50k.txt",
     "5351ff405b1126ef555791dd4d9798a48e3e9a501a9fc481a9da957752cfb458"),
]


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def check_sums() -> bool:
    ok = True
    for line in (DIR / "SHA256SUMS").read_text().splitlines():
        want, name = line.split(maxsplit=1)
        got = sha256((DIR / name).read_bytes())
        if got != want:
            print(f"MISMATCH {name}: {got}, recorded {want}")
            ok = False
    return ok


def build() -> bytes:
    lp: dict[str, float] = {}
    for url, want in SOURCES:
        with urllib.request.urlopen(url, timeout=60) as response:
            data = response.read()
        if sha256(data) != want:
            sys.exit(f"{url}: sha256 {sha256(data)} is not the pinned {want}")
        text = io.TextIOWrapper(io.BytesIO(data), encoding="utf-8")   # read lines exactly as open() does
        rows = [line.split() for line in text if line.strip()]
        rows = [(r[0].lower(), int(r[1])) for r in rows if len(r) >= 2 and r[1].isdigit()]
        total = sum(c for _, c in rows)
        for w, c in rows:
            v = math.log(c / total)
            if v > lp.get(w, -99):
                lp[w] = v
    words = sorted(w for w in lp if re.fullmatch(r"[a-z]+", w))
    return "".join(f"{w}\t{lp[w]!r}\n" for w in words).encode()


if __name__ == "__main__":
    same = True
    if "--check" not in sys.argv:
        rebuilt = build()
        if "--write" in sys.argv:
            LIST.write_bytes(rebuilt)
            print(f"wrote {LIST.relative_to(ROOT)}: {len(rebuilt)} bytes, sha256 {sha256(rebuilt)}")
        else:
            shipped = LIST.read_bytes().splitlines()
            differ = sum(a != b for a, b in zip(shipped, rebuilt.splitlines())) + abs(len(shipped) - len(rebuilt.splitlines()))
            same = differ == 0
            print(f"rebuilt list sha256 {sha256(rebuilt)}: " + ("identical to the shipped list" if same else f"{differ} lines differ from the shipped list"))
    sys.exit(0 if check_sums() and same else 1)
