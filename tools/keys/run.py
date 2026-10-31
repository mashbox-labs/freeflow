import json, sys, itertools, os, re
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import sim
from geometry import comfort, classic, ComfortSpec
PPM = {"iphone_air": 460/25.4/3, "ipad_air11": 264/25.4/2}
W, H, ppm = 420.0, 280.0, PPM["iphone_air"]
K = float(os.environ.get("TYPED_PER_MSG", "10"))   # typed keystrokes per dictated message (usage-mix assumption)
def cost(r):  # expected seconds per dictated message; a typed error costs delete + retype, a missed mic/return a retap
    t = r["ms_per_key"]/1000
    return (r["mic_ms"]/1000)*(1+r["mic_miss_pct"]/100) + (r["ret_ms"]/1000)*(1+r["ret_miss_pct"]/100) + K*t*(1+2*r["err_pct"]/100)
# usage-mix weights (taps per dictated message) from the DEV text only
_raw = "".join(sim.gutenberg(f) for f in sim.SETS["dev"])
_ks = [k for m in sim.messages("dev") for k, _ in sim.keystrokes(m)]
P_SPACE = _ks.count("space") / len(_ks); P_SHIFT = _ks.count("shift") / len(_ks)
P_123 = len(re.findall(r"[0-9.,?!;:'\"()-]", _raw)) / max(len(re.sub(r"\s+", "", _raw)), 1)
WEIGHTS = {"mic": 1.0, "style": 0.02, "return": 1.0, "space": K * P_SPACE, "abc123": K * P_123 * 2, "globe": 0.02}
def spec_for(ha, hb, letter_min=7.3):
    lh = (H-ha-hb)/3
    return ComfortSpec(action=[("style", WEIGHTS["style"], 9.2, 84.0), ("mic", WEIGHTS["mic"], 9.2)],
                       bottom=[("abc123", WEIGHTS["abc123"], 9.2), ("globe", WEIGHTS["globe"], 7.3), ("space", WEIGHTS["space"], 9.2, 5.0), ("return", WEIGHTS["return"], 9.2)],row_mm={"action": ha/ppm, "letter": lh/ppm, "bottom": hb/ppm},
                       row_min_mm={"action": 7.3, "letter": letter_min, "bottom": 7.3})
lm, _ = sim.train_lm()
dev = sim.messages("dev", 1500, seed=11)
held = sim.messages("heldout", 1500, seed=23)
res = {}
# 1) geometry on dev (no letter model): row heights
grid = []
for ha in range(44, 85, 4):
    for hb in range(44, 93, 4):
        if (H-ha-hb)/3 < 40: continue
        keys = comfort(W, H, ppm, spec_for(ha, hb))
        r = sim.run(keys, dev, ppm, seed=5)
        grid.append((cost(r), ha, hb, r))
grid.sort(key=lambda g: g[0])
# declared rule: among layouts within 0.5% of the best dev cost, take the most even rows (largest smallest row)
near = [g for g in grid if g[0] <= grid[0][0] * 1.005]
c, ha, hb, r = max(near, key=lambda g: (min(g[1], g[2], (H - g[1] - g[2]) / 3), -g[0]))
res["dev_near_count"] = len(near)
res["dev_best_rows"] = {"action_pt": ha, "bottom_pt": hb, "letter_pt": round((H-ha-hb)/3,2), "cost_s_per_msg": round(c,4)}
res["dev_top5"] = [(round(g[0],4), g[1], g[2]) for g in grid[:5]]
keys_c = comfort(W, H, ppm, spec_for(ha, hb))
# 2) letter model weight + anchor on dev
best = None
for lam, alpha in itertools.product([0, 0.25, 0.5, 0.75, 1.0, 1.5], [0.3, 0.5, 0.7]):
    r = sim.run(keys_c, dev, ppm, lm=lm, lam=lam, alpha=alpha, seed=5)
    if best is None or r["err_pct"] < best[0]["err_pct"]: best = (r, lam, alpha)
res["dev_best_lm"] = {"lam": best[1], "alpha": best[2], "dev_err_pct": round(best[0]["err_pct"],3)}
lam, alpha = best[1], best[2]
# 3) held-out report (nothing tuned here)
keys_k = classic(W, H)
rep = {}
for tail in (False, True):
    tag = "heavy_tail" if tail else "gaussian"
    rep[tag] = {
      "classic": sim.run(keys_k, held, ppm, tail=tail, seed=99),
      "comfort": sim.run(keys_c, held, ppm, tail=tail, seed=99),
      "comfort_lm": sim.run(keys_c, held, ppm, lm=lm, lam=lam, alpha=alpha, tail=tail, seed=99)}
    for k,v in rep[tag].items(): v["cost_s_per_msg"] = round(cost(v),4)
res["heldout_ESTIMATED"] = rep
res["typed_per_msg"] = K; res["weights"] = WEIGHTS; res["dev_shares"] = {"space": P_SPACE, "shift": P_SHIFT, "p123": P_123}
res["geometry"] = {"comfort": [(k.id, [round(v,2) for v in k.hit], [round(v,2) for v in k.vis]) for k in keys_c],
                   "classic": [(k.id, [round(v,2) for v in k.hit]) for k in keys_k]}
json.dump(res, open(f"results-k{int(K)}.json","w"), indent=1)
def fmt(v): return {k: round(x,2) if isinstance(x,float) else x for k,x in v.items()}
print(json.dumps({k: res[k] for k in ("dev_best_rows","dev_near_count","dev_best_lm","typed_per_msg","weights")}))
for tag in rep:
    for k,v in rep[tag].items(): print(tag, k, fmt(v))

fx = {"W": W, "H": H, "ppm": ppm, "spec": {"row_mm": spec_for(ha, hb).row_mm, "action": spec_for(ha, hb).action, "bottom": spec_for(ha, hb).bottom},
      "keys": [{"id": k.id, "hit": k.hit, "vis": k.vis} for k in keys_c], "lam": lam, "alpha": alpha}
json.dump(fx, open(f"fixture-k{int(K)}.json", "w"), indent=0)
for k in keys_c:
    if k.kind != "letter" or k.id in "qa": print("COMFORT", k.id, [round(v,1) for v in k.hit], "vis", [round(v,1) for v in k.vis])
