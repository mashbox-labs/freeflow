"""Comfort v1 vs v2 (v2: hide key, wide mic, L return clear of backspace) on HELD-OUT text, same tap
model and letter model as v1 (nothing re-tuned). ESTIMATED: simulated taps, not people. Also writes
fixture-v2.json for the Swift parity test."""
import json, random, sys, os, struct
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import sim
from geometry import comfort, classic, ComfortSpec, hit_test
fx = json.load(open("fixture-k5.json"))
W, H, ppm, lam, alpha = fx["W"], fx["H"], fx["ppm"], fx["lam"], fx["alpha"]
sp = fx["spec"]
def spec(v2, hand="right"):
    s = ComfortSpec(row_mm=sp["row_mm"], action=[tuple(a) for a in sp["action"]], bottom=[tuple(b) for b in sp["bottom"]])
    if v2:
        s.action = [("hide", 0.02, 9.2)] + s.action
        s.hand = hand
    else:
        s.split, s.drop = 0.0, 0.0
    return s
lm, _ = sim.train_lm()
# the shipped letter model is Int16 log-probs x 1000: use the same quantised table
lmq = [[[max(-32768, round(lm[a][b][c] * 1000)) / 1000 for c in range(27)] for b in range(27)] for a in range(27)]
held = sim.messages("heldout", 1500, seed=23)
out = {}
for K in (5, 10):
    os.environ["TYPED_PER_MSG"] = str(K)
    for tail in (False, True):
        tag = f"k{K}_{'heavy_tail' if tail else 'gaussian'}"
        out[tag] = {}
        for name, keys, use_lm in (("classic", classic(W, H), False), ("comfort_v1", comfort(W, H, ppm, spec(False)), True),
                                   ("comfort_v2", comfort(W, H, ppm, spec(True)), True), ("comfort_v2_left", comfort(W, H, ppm, spec(True, "left")), True)):
            r = sim.run(keys, held[: 1500], ppm, lm=lmq if use_lm else None, lam=lam if use_lm else 0.0, alpha=alpha, tail=tail, seed=99)
            out[tag][name] = {k: round(v, 3) if isinstance(v, float) else v for k, v in r.items()}
json.dump(out, open("results-v2.json", "w"), indent=1)
for tag, d in out.items():
    if not tag.startswith("k5"): continue
    for n, r in d.items():
        print(tag, f"{n:16s} err {r['err_pct']:5.2f}% (drop {r['dropped_pct']:.2f}) ms/key {r['ms_per_key']:.0f} mic miss {r['mic_miss_pct']:.2f}% {r['mic_ms']:.0f}ms ret miss {r['ret_miss_pct']:.2f}% {r['ret_ms']:.0f}ms")
# fixture for Swift parity
keys = comfort(W, H, ppm, spec(True))
keysL = comfort(W, H, ppm, spec(True, "left"))
dec = sim.Decoder(keys, sim.Taps(ppm), lmq, lam, alpha)
rnd = random.Random(2910)
cases = []
letters = [k for k in keys if k.kind == "letter"]
ctxs = ["wh", "  ", "an", "o ", " t", "in", "th", "qu"]
while len(cases) < 12:
    k = rnd.choice(letters); v = k.vis
    x = v[0] + v[2] / 2 + rnd.gauss(0, 12); y = v[1] + v[3] / 2 + rnd.gauss(0, 12)
    if not (0 <= x < W and 60 <= y < 209): continue
    ctx = rnd.choice(ctxs)
    plain = dec.hit(x, y); got = dec.decode(x, y, ctx)
    if plain is None: continue
    if len([c for c in cases if c[3] != c[4]]) < 4 or plain == got:
        cases.append((round(x, 3), round(y, 3), ctx, plain, got))
moat = [(x, y, (hit_test(keys, x, y).id if hit_test(keys, x, y) else None)) for x, y in ((380, 215), (400, 222.5), (358, 209.5), (356, 215), (380, 205), (380, 224.5), (300, 210))]
json.dump({"W": W, "H": H, "ppm": ppm, "lam": lam, "alpha": alpha,
           "keys": [{"id": k.id, "hit": k.hit, "vis": k.vis, "notch": k.notch, "vis2": k.vis2} for k in keys],
           "keys_left_action": [{"id": k.id, "hit": k.hit} for k in keysL if k.kind == "action"],
           "decode": cases, "moat": moat}, open("fixture-v2.json", "w"), indent=0)
print("decode cases", cases); print("moat", moat)
