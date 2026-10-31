"""Key geometry for Free Flow keyboards (Python reference; Swift twin: FreeFlowKit/KeyGeometry.swift).

Comfort is solved, not hand-placed:
  * every axis is split by weighted water-filling: maximise sum(w_i * ln s_i) with sum(s_i) = L and
    min_i <= s_i <= max_i. The optimum is s_i = clamp(lambda * w_i, min_i, max_i) (KKT), found by bisection.
    With w_i = tap frequency this is the Fitts-time optimum for log2(D/s) when D >> s (sizes proportional
    to use), bounded by research minimums.
  * QWERTY rows share one pitch p = W/10 with the usual 0.5p / 1.5p stagger.
  * hit areas tile the whole keyboard except one deliberate moat (below); the visible key is the hit tile inset by gap/2,
    with an edge margin at the outer edges, drawn `lift` points higher than its tile because taps land
    below the aimed point.
  * return/backspace (v2): the row-3 / bottom-row boundary sits `split` pt lower than the
    row split, so the visible gap between row 3 and the bottom row is gap + split (Apple's 11 pt) and the
    boundary favours the letters (sending half a message costs more than a stray letter). Return is an L:
    its tall part (label, where people aim) sits under n/m, its short part under backspace starts `drop` pt
    lower, and the strip between backspace and that short part is a dead moat (a tap there does nothing).
  * the action row has a hide key (dismiss keyboard); `hand` = 'left' mirrors the action row.
Units: points. Origin top-left of the keyboard view.
"""
from dataclasses import dataclass, field
import math

@dataclass
class Key:
    id: str          # 'q', 'shift', 'delete', 'abc123', 'globe', 'space', 'return', 'mic', 'style'
    hit: tuple       # x, y, w, h  (tile, tiles cover the keyboard)
    vis: tuple       # x, y, w, h  (drawn key)
    kind: str        # 'letter' | 'special' | 'action'
    notch: tuple = None  # x, y, w, h cut out of the tile (return's moat corner); dead, belongs to no key
    vis2: tuple = None   # second drawn rect (return's short part under backspace)

def inside(r, x, y):
    return r[0] <= x < r[0] + r[2] and r[1] <= y < r[1] + r[3]

def hit_test(keys, x, y):
    """The key under a point; None in the moat. Mirrors KeyGeometry.key(at:in:) in Swift."""
    for k in keys:
        if inside(k.hit, x, y) and not (k.notch and inside(k.notch, x, y)):
            return k
    return None

def waterfill(total, weights, mins, maxs=None, iters=80):
    n = len(weights)
    maxs = list(maxs) if maxs else [math.inf] * n
    smin = sum(mins)
    if smin >= total:
        return [m * total / smin for m in mins]
    if all(math.isfinite(m) for m in maxs) and sum(maxs) <= total:
        extra, wsum = total - sum(maxs), sum(weights)
        return [mx + extra * w / wsum for mx, w in zip(maxs, weights)]
    f = lambda lam: sum(min(max(lam * w, mn), mx) for w, mn, mx in zip(weights, mins, maxs))
    lo, hi = 0.0, 1.0
    while f(hi) < total:
        hi *= 2
    for _ in range(iters):
        mid = (lo + hi) / 2
        if f(mid) < total: lo = mid
        else: hi = mid
    s = [min(max(hi * w, mn), mx) for w, mn, mx in zip(weights, mins, maxs)]
    # put the bisection residual on the largest item that is not pinned
    free = [i for i in range(n) if mins[i] < s[i] < maxs[i]] or list(range(n))
    j = max(free, key=lambda i: s[i])
    s[j] += total - sum(s)
    return s

@dataclass
class ComfortSpec:
    # vertical targets (mm): water-filled into the keyboard height
    row_mm: dict = field(default_factory=lambda: {"action": 9.6, "letter": 8.6, "bottom": 9.6})
    row_min_mm: dict = field(default_factory=lambda: {"action": 7.3, "letter": 7.3, "bottom": 7.3})
    # horizontal weights = taps per dictated message (usage mix), mins in mm (research floors)
    action: list = field(default_factory=lambda: [("hide", 0.02, 9.2), ("style", 0.05, 9.2), ("mic", 1.0, 9.2)])
    bottom: list = field(default_factory=lambda: [("abc123", 0.35, 9.2), ("globe", 0.05, 7.3), ("space", 2.6, 9.2), ("return", 1.0, 9.2)])
    gap: float = 6.0       # visible gap between keys (pt)
    edge: float = 3.0      # visible margin at the keyboard's outer edges (pt)
    lift: float = 0.0      # visible key drawn this many pt above its hit tile centre
    split: float = 5.0     # row-3 / bottom-row boundary this many pt below the row split (visible gap = gap + split)
    favour: float = 3.0    # and the hit boundary this many pt lower again, at the bottom row's drawn top edge
    drop: float = 15.0     # return's part under backspace is drawn this many pt lower; the strip above it is dead
    hand: str = "right"    # 'left' mirrors the action row (mic on the left)

def letters_rows():
    return ["qwertyuiop", "asdfghjkl", "zxcvbnm"]

def _vis(hit, W, H, gap, edge, lift):
    x, y, w, h = hit
    l = edge if x <= 0.01 else gap / 2
    r = edge if x + w >= W - 0.01 else gap / 2
    t = edge if y <= 0.01 else gap / 2
    b = edge if y + h >= H - 0.01 else gap / 2
    return (x + l, y + t - lift, w - l - r, h - t - b)

def comfort(W, H, pt_per_mm, spec=None, globe=False):
    s = spec or ComfortSpec()
    mm = lambda v: v * pt_per_mm
    names = ["action", "letter", "letter", "letter", "bottom"]
    hs = waterfill(H, [mm(s.row_mm[n]) for n in names], [mm(s.row_min_mm[n]) for n in names])
    # letter rows share one height (QWERTY rows look the same): average the three
    lh = (hs[1] + hs[2] + hs[3]) / 3
    hs = [hs[0], lh, lh, lh, hs[4]]
    ys = [sum(hs[:i]) for i in range(5)]
    keys = []
    def add(id_, hit, kind):
        keys.append(Key(id_, hit, _vis(hit, W, H, s.gap, s.edge, s.lift), kind))
    # action row
    items = s.action if s.hand != "left" else list(reversed(s.action))
    ws = waterfill(W, [it[1] for it in items], [max(mm(it[2]), it[3] if len(it) > 3 else 0) for it in items])
    x = 0.0
    for it, w in zip(items, ws):
        add(it[0], (x, ys[0], w, hs[0]), "action"); x += w
    # letter rows
    p = W / 10
    r1, r2, r3 = letters_rows()
    for i, c in enumerate(r1):
        add(c, (i * p, ys[1], p, hs[1]), "letter")
    for i, c in enumerate(r2):
        x0 = 0.0 if i == 0 else (i + 0.5) * p
        x1 = W if i == len(r2) - 1 else (i + 1.5) * p
        add(c, (x0, ys[2], x1 - x0, hs[2]), "letter")
    add("shift", (0.0, ys[3], 1.5 * p, hs[3]), "special")
    for i, c in enumerate(r3):
        add(c, ((i + 1.5) * p, ys[3], p, hs[3]), "letter")
    add("delete", (8.5 * p, ys[3], W - 8.5 * p, hs[3]), "special")
    # bottom row
    items = [it for it in s.bottom if globe or it[0] != "globe"]
    ws = waterfill(W, [it[1] for it in items], [max(mm(it[2]), (it[3] * W / 10 if it[0] == "space" else it[3]) if len(it) > 3 else mm(it[2])) for it in items])
    x = 0.0
    for it, w in zip(items, ws):
        add(it[0], (x, ys[4], w, hs[4]), "special"); x += w
    # v2: move the row-3 / bottom-row boundary down by `split`; row 3 keeps its drawn size
    sp, fv = s.split, (s.favour if s.split > 0 else 0.0)
    for k in keys:
        x0, y0, w0, h0 = k.hit
        vx, vy, vw, vh = k.vis
        if abs(y0 - ys[3]) < 0.01:
            k.hit = (x0, y0, w0, h0 + sp + fv)
        elif abs(y0 - ys[4]) < 0.01:
            k.hit = (x0, y0 + sp + fv, w0, h0 - sp - fv)
            k.vis = (vx, vy + sp, vw, vh - sp)
    # v2: return is an L; its part under backspace starts `drop` lower, the strip above it is dead
    ret = next(k for k in keys if k.id == "return")
    xd = 8.5 * p
    rx, ry, rw, rh = ret.hit
    if s.drop > 0 and rx < xd - p / 2:
        ret.notch = (xd, ry, W - xd, s.drop - fv)
        vx, vy, vw, vh = ret.vis
        ret.vis = (vx, vy, xd - s.gap / 2 - vx, vh)                       # tall part: label, aim point
        ret.vis2 = (xd + s.gap / 2, vy + s.drop, vx + vw - xd - s.gap / 2, vh - s.drop)
    # the letter in row 2 edges: draw a and l at normal width (tile wider, key not)
    for k in keys:
        if k.id in ("a", "l"):
            vx, vy, vw, vh = k.vis
            nw = p - s.gap
            k.vis = (vx + (vw - nw) if k.id == "a" else vx, vy, nw, vh)
    return keys

def classic(W, H=280.0, globe=False):
    """Today's layout, rebuilt from KeyboardViewController.swift @8160f03 (SwiftUI HStack/VStack rules).
    Hit area = visible frame (Buttons; the gaps are dead). Vertical placement is replaced by the
    measured frames from the UI dump when available (see measured.json)."""
    keys = []
    padx = 4 + 3
    inner = W - 2 * padx
    rowh, vgap = 44.0, 9.0
    topbar_h, spacing = 46.0, 8.0
    keys_h = 4 * rowh + 3 * vgap
    avail = H - 12 - topbar_h - spacing
    y0 = 6 + topbar_h + spacing + (avail - keys_h) / 2
    ys = [y0 + i * (rowh + vgap) for i in range(4)]
    def add(id_, r, kind):
        keys.append(Key(id_, r, r, kind))
    # top bar: mic circle 46 centred, style pill at left
    add("mic", (W / 2 - 23, 6.0, 46.0, 46.0), "action")
    add("style", (12.0, 6.0 + (46 - 35) / 2, 88.0, 35.0), "action")
    r1, r2, r3 = letters_rows()
    kw = (inner - 9 * 6) / 10
    for i, c in enumerate(r1):
        add(c, (padx + i * (kw + 6), ys[0], kw, rowh), "letter")
    kw2 = (inner - 32 - 8 * 6) / 9
    for i, c in enumerate(r2):
        add(c, (padx + 16 + i * (kw2 + 6), ys[1], kw2, rowh), "letter")
    add("shift", (padx, ys[2], 46.0, rowh), "special")
    add("delete", (W - padx - 46, ys[2], 46.0, rowh), "special")
    x3 = padx + 46 + 6 + 6
    kw3 = (inner - 92 - 12 - 12 - 6 * 6) / 7
    for i, c in enumerate(r3):
        add(c, (x3 + i * (kw3 + 6), ys[2], kw3, rowh), "letter")
    add("abc123", (padx, ys[3], 46.0, rowh), "special")
    x = padx + 52
    if globe:
        add("globe", (x, ys[3], 46.0, rowh), "special"); x += 52
    add("return", (W - padx - 46, ys[3], 46.0, rowh), "special")
    add("space", (x, ys[3], W - padx - 46 - 6 - x, rowh), "special")
    return keys
