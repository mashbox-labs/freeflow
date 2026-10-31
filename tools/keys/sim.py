"""Tap simulator: ESTIMATED error rate and Fitts time per key for a keyboard layout.

Taps for an intended key = visible key centre + mean offset + spread (mm -> pt with the device's pt/mm).
Spread and offsets come from tapmodel.json, every number cited there. Decoders:
  hit   : the key whose hit rect holds the tap; none = dropped key (Classic gaps are dead)
  lm    : hit, then for letters a Bayes choice among nearby letters: log N(tap | key) + lam * log P(key | 2 prev chars),
          except taps inside the key's anchor box (central alpha of the visible key), which always give that key.
Time: Fitts (Shannon form) MT = a + b * log2(D / W + 1), W = smaller side of the visible key, D = centre distance.
Run: python3 -I sim.py <mode> ...   (see main)
"""
import json, math, random, re, sys, os
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from geometry import comfort, classic, ComfortSpec, hit_test

HERE = os.path.dirname(os.path.abspath(__file__))
CORPUS = os.environ.get("KEYS_CORPUS", os.path.join(HERE, "..", "corpus"))
TM = json.load(open(os.path.join(HERE, "tapmodel.json")))
ALPHA = "abcdefghijklmnopqrstuvwxyz"

def gutenberg(name):
    t = open(os.path.join(CORPUS, name), encoding="utf-8", errors="ignore").read()
    a = t.find("*** START OF"); b = t.find("*** END OF")
    t = t[t.find("\n", a) + 1:b] if a >= 0 and b > a else t
    return t

def sentences(text):
    text = re.sub(r"\s+", " ", text)
    out = []
    for s in re.split(r"(?<=[.!?])\s+", text):
        s = re.sub(r"[^A-Za-z ]", "", s).strip()
        s = re.sub(r" +", " ", s)
        if 3 <= len(s.split()) <= 25:
            out.append(s)
    return out

def phrases():
    return [l.strip() for l in open(os.path.join(CORPUS, "phrases", "phrases2.txt")) if l.strip()]

SETS = {
    "lm":      ["pg1342.txt", "pg1661.txt", "pg98.txt", "pg2701.txt"],
    "dev":     ["pg76.txt", "pg11.txt"],
    "heldout": ["pg84.txt"],          # + MacKenzie & Soukoreff phrase set
}

def messages(split, n=None, seed=1):
    msgs = []
    for f in SETS[split]:
        msgs += sentences(gutenberg(f))
    if split == "heldout":
        msgs += phrases()
    rnd = random.Random(seed)
    rnd.shuffle(msgs)
    return msgs[:n] if n else msgs

# ---------- letter model (char trigram, 27 symbols) ----------
def norm(ch):
    ch = ch.lower()
    return ch if ch in ALPHA else " "

def train_lm(k=0.5):
    from collections import defaultdict
    cnt = [[[0] * 27 for _ in range(27)] for _ in range(27)]
    idx = lambda c: 26 if c == " " else ord(c) - 97
    for f in SETS["lm"]:
        t = " " + re.sub(r" +", " ", "".join(norm(c) for c in gutenberg(f)))
        for i in range(2, len(t)):
            cnt[idx(t[i - 2])][idx(t[i - 1])][idx(t[i])] += 1
    lp = [[[0.0] * 27 for _ in range(27)] for _ in range(27)]
    for a in range(27):
        for b in range(27):
            s = sum(cnt[a][b]) + 27 * k
            for c in range(27):
                lp[a][b][c] = math.log((cnt[a][b][c] + k) / s)
    return lp, cnt

# ---------- keystrokes ----------
def keystrokes(msg):
    ks = []
    for ch in msg:
        if ch == " ": ks.append(("space", " "))
        elif ch.isupper(): ks += [("shift", None), (ch.lower(), ch)]
        elif ch in ALPHA: ks.append((ch, ch))
    return ks

# ---------- tap model ----------
class Taps:
    def __init__(self, ppm, tail=False, seed=7):
        self.ppm, self.tail, self.rnd = ppm, tail, random.Random(seed)
        t = TM["tap"]
        self.sx, self.sy = t["sd_x_mm"] * ppm, t["sd_y_mm"] * ppm
        self.mx, self.my = t["mean_x_mm"] * ppm, t["mean_y_mm"] * ppm
        self.rel = t.get("relative_sd_per_width", 0.0)
    def sd(self, vis):
        # FFitts: sigma^2 = sigma_a^2 + (rel * W)^2  (wider targets are aimed less tightly)
        rx, ry = self.rel * vis[2], self.rel * vis[3]
        return math.hypot(self.sx, rx), math.hypot(self.sy, ry)
    def tap(self, vis):
        cx, cy = vis[0] + vis[2] / 2, vis[1] + vis[3] / 2
        sx, sy = self.sd(vis)
        k = 2.5 if (self.tail and self.rnd.random() < 0.05) else 1.0
        return cx + self.mx + self.rnd.gauss(0, sx * k), cy + self.my + self.rnd.gauss(0, sy * k)

def inside(r, x, y):
    return r[0] <= x < r[0] + r[2] and r[1] <= y < r[1] + r[3]

class Decoder:
    def __init__(self, keys, taps, lm=None, lam=0.0, alpha=0.5):
        self.keys = keys; self.by = {k.id: k for k in keys}; self.taps = taps
        self.lm, self.lam, self.alpha = lm, lam, alpha
        self.letters = [k for k in keys if k.kind == "letter"]
    def hit(self, x, y):
        k = hit_test(self.keys, x, y)   # None in return's dead moat
        return k.id if k else None
    def decode(self, x, y, ctx):
        g = self.hit(x, y)
        if self.lm is None or g is None or self.by[g].kind != "letter":
            return g
        a = self.by[g].vis
        ax, ay = a[2] * (1 - self.alpha) / 2, a[3] * (1 - self.alpha) / 2
        if inside((a[0] + ax, a[1] + ay, a[2] - 2 * ax, a[3] - 2 * ay), x, y):
            return g
        i2 = 26 if ctx[0] == " " else ord(ctx[0]) - 97
        i1 = 26 if ctx[1] == " " else ord(ctx[1]) - 97
        best, bs = g, -1e18
        for k in self.letters:
            v = k.vis; cx = v[0] + v[2] / 2 + self.taps.mx; cy = v[1] + v[3] / 2 + self.taps.my
            sx, sy = self.taps.sd(v)
            dx, dy = (x - cx) / sx, (y - cy) / sy
            if dx * dx + dy * dy > 16: continue
            s = -0.5 * (dx * dx + dy * dy) - math.log(sx * sy) + self.lam * self.lm[i2][i1][ord(k.id) - 97]
            if s > bs: best, bs = k.id, s
        return best

def fitts(prev, cur):
    a, b = TM["fitts"]["a_s"], TM["fitts"]["b_s_per_bit"]
    W = min(cur[2], cur[3])
    if prev is None: return a + b * 1.0
    D = math.hypot(prev[0] + prev[2] / 2 - cur[0] - cur[2] / 2, prev[1] + prev[3] / 2 - cur[1] - cur[3] / 2)
    return a + b * math.log2(D / W + 1)

def run(keys, msgs, ppm, lm=None, lam=0.0, alpha=0.5, tail=False, seed=7, typed=True):
    taps = Taps(ppm, tail=tail, seed=seed)
    dec = Decoder(keys, taps, lm, lam, alpha)
    by = dec.by
    st = {"keys": 0, "wrong": 0, "dropped": 0, "time": 0.0,
          "mic_n": 0, "mic_err": 0, "mic_t": 0.0, "ret_n": 0, "ret_err": 0, "ret_t": 0.0}
    for m in msgs:
        prev = by["return"].vis
        # dictation loop: mic (from return), then the message is typed (typed=True) or dictated, then return
        x, y = taps.tap(by["mic"].vis)
        st["mic_n"] += 1; st["mic_err"] += dec.hit(x, y) != "mic"; st["mic_t"] += fitts(prev, by["mic"].vis)
        prev = by["mic"].vis
        ctx = "  "
        if typed:
            for kid, ch in keystrokes(m):
                v = by[kid].vis
                x, y = taps.tap(v)
                got = dec.decode(x, y, ctx) if kid in ALPHA else dec.hit(x, y)
                st["keys"] += 1; st["time"] += fitts(prev, v)
                if got is None: st["dropped"] += 1
                elif got != kid: st["wrong"] += 1
                prev = v
                if ch is not None: ctx = ctx[1] + norm(ch)
        v = by["return"].vis
        x, y = taps.tap(v)
        st["ret_n"] += 1; st["ret_err"] += dec.hit(x, y) != "return"; st["ret_t"] += fitts(prev, v)
    k = max(st["keys"], 1)
    return {"keys": st["keys"], "err_pct": 100 * (st["wrong"] + st["dropped"]) / k,
            "wrong_pct": 100 * st["wrong"] / k, "dropped_pct": 100 * st["dropped"] / k,
            "ms_per_key": 1000 * st["time"] / k,
            "mic_miss_pct": 100 * st["mic_err"] / max(st["mic_n"], 1), "mic_ms": 1000 * st["mic_t"] / max(st["mic_n"], 1),
            "ret_miss_pct": 100 * st["ret_err"] / max(st["ret_n"], 1), "ret_ms": 1000 * st["ret_t"] / max(st["ret_n"], 1)}
