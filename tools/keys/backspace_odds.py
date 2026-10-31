"""Where taps aimed at return and at backspace land: return->backspace, backspace->return, letters->return,
return->dead moat. 400,000 simulated taps per cell (ESTIMATED). Tap spread: the sim's model (FFitts 1.648 mm per
axis, optional 5% heavy tail x2.5) and a size-dependent one (FFitts 2D table, sigma_r = 0.56 + 0.10 W mm,
extrapolated past 7.2 mm). Aim = centre of the drawn key (return v2: its labelled tall part)."""
import json, random, math, sys, os
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from geometry import comfort, classic, ComfortSpec, hit_test, inside
fx = json.load(open("fixture-k5.json")); sp = fx["spec"]; W, H, ppm = fx["W"], fx["H"], fx["ppm"]
def spec(v2):
    s = ComfortSpec(row_mm=sp["row_mm"], action=[tuple(a) for a in sp["action"]], bottom=[tuple(b) for b in sp["bottom"]])
    if v2: s.action = [("hide", 0.02, 9.2)] + s.action
    else: s.split, s.drop = 0.0, 0.0
    return s
def classic_hit(keys, x, y):
    for k in keys:
        if inside(k.hit, x, y): return k
    return None
# Apple iOS 26, measured from a screenshot of the system keyboard in Termius (px/3); hit boundaries at mid-gap (assumed)
class K:
    def __init__(s, id, hit, vis): s.id, s.hit, s.vis, s.notch, s.vis2, s.kind = id, hit, vis, None, None, "letter" if len(id) == 1 else "special"
apple = [K("n", (272, 0, 41.3, 56), (275, 2.8, 35.3, 45)), K("m", (313.3, 0, 41.3, 56), (316.3, 2.8, 35.3, 45)),
         K("delete", (362.7, 0, 57.3, 56), (365.7, 2.8, 48, 45)),
         K("space", (106.7, 56, 206.7, 56), (109.7, 58.8, 200.7, 45)), K("return", (313.3, 56, 106.7, 56), (316.3, 58.8, 97.3, 45))]
layouts = {"Classic (today)": (classic(W, H), classic_hit), "Apple iOS 26": (apple, hit_test),
           "Comfort v1": (comfort(W, H, ppm, spec(False)), hit_test), "Comfort v2": (comfort(W, H, ppm, spec(True)), hit_test)}
def sd_model(model, vis):
    if model == "sim": return 1.648 * ppm, 1.648 * ppm
    f = lambda wpt: math.sqrt((1.5 ** 2 + (0.56 + 0.10 * wpt / ppm) ** 2) / 2) * ppm
    return f(vis[2]), f(vis[3])
N = 400_000
res = {}
for name, (keys, ht) in layouts.items():
    by = {k.id: k for k in keys}
    for model, tail in (("sim", False), ("sim", True), ("ffitts_size", False)):
        rnd = random.Random(4)
        row = {}
        for aim in ("return", "delete", "m", "n"):
            v = by[aim].vis; cx, cy = v[0] + v[2] / 2, v[1] + v[3] / 2
            sx, sy = sd_model(model, v)
            c = {}
            for _ in range(N):
                k = 2.5 if (tail and rnd.random() < 0.05) else 1.0
                g = ht(keys, cx + rnd.gauss(0, sx * k), cy + rnd.gauss(0, sy * k))
                gid = g.id if g else "nothing"
                if gid != aim: c[gid] = c.get(gid, 0) + 1
            row[aim] = {k2: round(100 * v2 / N, 4) for k2, v2 in sorted(c.items(), key=lambda t: -t[1])}
        tag = model + ("+tail" if tail else "")
        res.setdefault(name, {})[tag] = row
        r = row
        print(f"{name:16s} {tag:12s} return->backspace {r['return'].get('delete',0):.4f}%  backspace->return {r['delete'].get('return',0):.4f}%  m->return {r['m'].get('return',0):.4f}%  n->return {r['n'].get('return',0):.4f}%  return->nothing {r['return'].get('nothing',0):.3f}%  return->other {sum(v for k,v in r['return'].items() if k not in ('delete','nothing')):.3f}%")
json.dump(res, open("results-backspace.json", "w"), indent=1)
