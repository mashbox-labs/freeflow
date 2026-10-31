import CoreGraphics
import Foundation

/// Key geometry for the Free Flow keyboard's Comfort layout, solved from size targets instead of placed by hand.
///
/// - Every axis is split by weighted water-filling: maximise sum(w_i * ln s_i) subject to sum(s_i) = L and
///   min_i <= s_i <= max_i. The optimum is s_i = clamp(lambda * w_i, min_i, max_i); lambda is found by bisection.
///   With w_i = how often a key is pressed, this is the size split that minimises total Fitts's-law time when the
///   distance is large next to the size (sizes in proportion to use), with research minimums as floors.
/// - QWERTY rows keep one pitch p = W / 10 and the usual 0.5p and 1.5p offsets, so nothing has to be relearned.
/// - Hit areas tile the whole keyboard except one deliberate moat: no dead gaps between keys. The drawn key is its
///   tile inset by half the gap, with an edge margin at the outer edges, raised by `lift` because taps land a little
///   below where people aim.
/// - Return and backspace (v2, 2026-10-29): the row-3 / bottom-row line sits `split` pt lower, so the drawn gap
///   between them is Apple's 11 pt, and the hit line `favour` pt lower again, at the bottom row's drawn top edge (a
///   letter that sends half a message costs more than a stray letter). Return is an L, like a Tetris piece: its tall
///   part (with the label, where people aim) sits under n and m; its short part under backspace is drawn `drop` pt
///   lower, and the strip between backspace and it is a dead moat, so a sloppy tap there does nothing.
/// - The action row has a hide key; `hand == .left` mirrors the action row (Dictate on the left).
/// See tools/keys/ for the solver, the tap model and the sources of each number.
/// The keyboard layouts in Settings > Keyboard (2026-10-29: several layouts to experiment with, among them the
/// L-shaped return with delete after l). The letters sit on Apple's grid and the action row is on
/// top in every layout; they differ in where delete and return sit and how much room each gets. 2026-10-29: the
/// layout in use ("Current", Comfort v2) was the default then; Classic matches Apple's keyboard
/// with only the Free Flow row on top. The raw values are stored in the App Group, so they never change.
public enum KeyLayoutKind: String, CaseIterable, Sendable {
    case comfort, roomy = "l1", bigReturn = "l2", tallReturn = "l3", deleteAfterL = "l4", classic
    public var title: String {
        switch self {
        case .comfort: "Current"
        case .roomy: "L1 Roomy delete"
        case .bigReturn: "L2 Big return"
        case .tallReturn: "L3 Tall return"
        case .deleteAfterL: "L4 Delete after L"
        case .classic: "Classic"
        }
    }
    /// One line on what is different (Settings > Keyboard > Layout).
    public var detail: String {
        switch self {
        case .comfort: "A big L-shaped return in the corner, delete next to it."
        case .roomy: "Comfort with clear space around delete. A near miss types space or return."
        case .bigReturn: "Wider return, clear space around delete, shorter space bar."
        case .tallReturn: "Return is one tall key in the corner. Longer space bar."
        case .deleteAfterL: "The a to l row moves left and delete sits right after l. Return keeps its L."
        case .classic: "The default. Apple's keyboard, key for key, with the Dictate row on top."
        }
    }
}

public enum KeyHand: String, CaseIterable, Sendable {
    case right, left
    public var title: String { self == .right ? "Right" : "Left" }
}

public struct KeySlot: Equatable, Sendable {
    public enum Kind: String, Sendable { case letter, special, action }
    public let id: String
    public let hit: CGRect
    public let visible: CGRect
    public let kind: Kind
    /// Cut out of `hit`: return's dead moat under backspace. A point here belongs to no key.
    public var notch: CGRect? = nil
    /// Second drawn part: return's short part under backspace.
    public var visible2: CGRect? = nil

    public init(id: String, hit: CGRect, visible: CGRect, kind: Kind, notch: CGRect? = nil, visible2: CGRect? = nil) {
        self.id = id; self.hit = hit; self.visible = visible; self.kind = kind; self.notch = notch; self.visible2 = visible2
    }

    /// Everything drawn for the key (both parts of the return).
    public var drawn: CGRect { visible2.map { visible.union($0) } ?? visible }

    public func contains(_ p: CGPoint) -> Bool { hit.contains(p) && !(notch?.contains(p) ?? false) }
}

public struct ComfortSpec: Sendable {
    public struct Item: Sendable {
        public let id: String
        public let weight: Double   // taps per dictated message (usage mix)
        public let minMM: Double    // research floor
        public let minPt: Double    // content floor (label must fit)
        public let minPitch: Double // familiarity floor in letter widths (space keeps the system keyboard's 5)
        public init(_ id: String, weight: Double, minMM: Double, minPt: Double = 0, minPitch: Double = 0) {
            self.id = id; self.weight = weight; self.minMM = minMM; self.minPt = minPt; self.minPitch = minPitch
        }
    }
    /// Row height targets and floors in millimetres: action row, each letter row, bottom row.
    public var rowMM: (action: Double, letter: Double, bottom: Double)
    public var rowMinMM: (action: Double, letter: Double, bottom: Double)
    public var action: [Item]
    public var bottom: [Item]
    public var gap: Double
    public var edge: Double
    public var lift: Double
    /// Row-3 / bottom-row line this many pt lower (drawn gap = gap + split), hit line `favour` lower again,
    /// return's part under backspace drawn `drop` lower with a dead strip above it. 0 / 0 / 0 = v1.
    public var split: Double
    public var favour: Double
    public var drop: Double

    public init(rowMM: (action: Double, letter: Double, bottom: Double),
                rowMinMM: (action: Double, letter: Double, bottom: Double),
                action: [Item], bottom: [Item], gap: Double, edge: Double, lift: Double,
                split: Double = 5, favour: Double = 3, drop: Double = 15) {
        self.rowMM = rowMM; self.rowMinMM = rowMinMM; self.action = action; self.bottom = bottom
        self.gap = gap; self.edge = edge; self.lift = lift
        self.split = split; self.favour = favour; self.drop = drop
    }
}

public enum KeyGeometry {
    public static let letterRows = ["qwertyuiop", "asdfghjkl", "zxcvbnm"]
    public static let symbolRows = ["1234567890", "-/:;()$&@\"", ".,?!'"]

    /// Points per millimetre for the current screen: points are pixels / scale, and the panel density is
    /// known per device class (iPhone Air and most recent iPhones 460 ppi at 3x; iPads 264 ppi at 2x).
    public static func pointsPerMM(ppi: Double, scale: Double) -> Double { ppi / 25.4 / scale }

    /// Water-filling: s_i = clamp(lambda * w_i, min_i, max_i) with sum(s_i) == total.
    public static func waterfill(_ total: Double, weights: [Double], mins: [Double], maxs: [Double]? = nil) -> [Double] {
        let n = weights.count
        let maxs = maxs ?? Array(repeating: Double.infinity, count: n)
        let smin = mins.reduce(0, +)
        if smin >= total { return mins.map { $0 * total / smin } }
        if maxs.allSatisfy({ $0.isFinite }) && maxs.reduce(0, +) <= total {
            let extra = total - maxs.reduce(0, +), wsum = weights.reduce(0, +)
            return zip(maxs, weights).map { $0 + extra * $1 / wsum }
        }
        func fill(_ lam: Double) -> [Double] { (0..<n).map { min(max(lam * weights[$0], mins[$0]), maxs[$0]) } }
        var lo = 0.0, hi = 1.0
        while fill(hi).reduce(0, +) < total { hi *= 2 }
        for _ in 0..<80 {
            let mid = (lo + hi) / 2
            if fill(mid).reduce(0, +) < total { lo = mid } else { hi = mid }
        }
        var s = fill(hi)
        var free = (0..<n).filter { mins[$0] < s[$0] && s[$0] < maxs[$0] }
        if free.isEmpty { free = Array(0..<n) }
        let j = free.max { s[$0] < s[$1] }!
        s[j] += total - s.reduce(0, +)
        return s
    }

    public static func comfort(width W: Double, height H: Double, pointsPerMM ppm: Double,
                               spec: ComfortSpec = .phone, globe: Bool = false, symbols: Bool = false,
                               hand: KeyHand = .right) -> [KeySlot] {
        func mm(_ v: Double) -> Double { v * ppm }
        let targets = [spec.rowMM.action, spec.rowMM.letter, spec.rowMM.letter, spec.rowMM.letter, spec.rowMM.bottom].map(mm)
        let floors = [spec.rowMinMM.action, spec.rowMinMM.letter, spec.rowMinMM.letter, spec.rowMinMM.letter, spec.rowMinMM.bottom].map(mm)
        var hs = waterfill(H, weights: targets, mins: floors)
        let lh = (hs[1] + hs[2] + hs[3]) / 3
        hs = [hs[0], lh, lh, lh, hs[4]]
        let ys = (0..<5).map { i in hs[..<i].reduce(0, +) }
        var keys: [KeySlot] = []
        func add(_ id: String, _ hit: CGRect, _ kind: KeySlot.Kind) {
            keys.append(KeySlot(id: id, hit: hit, visible: visible(hit, W: W, H: H, spec: spec), kind: kind))
        }
        func row(_ items: [ComfortSpec.Item], y: Double, h: Double, kind: KeySlot.Kind) {
            let ws = waterfill(W, weights: items.map(\.weight), mins: items.map { max(mm($0.minMM), $0.minPt, $0.minPitch * W / 10) })
            var x = 0.0
            for (item, w) in zip(items, ws) { add(item.id, CGRect(x: x, y: y, width: w, height: h), kind); x += w }
        }
        row(hand == .left ? spec.action.reversed() : spec.action, y: ys[0], h: hs[0], kind: .action)
        let p = W / 10
        if symbols {
            for (i, c) in Array(symbolRows[0]).enumerated() { add(String(c), CGRect(x: Double(i) * p, y: ys[1], width: p, height: hs[1]), .letter) }
            for (i, c) in Array(symbolRows[1]).enumerated() { add(String(c), CGRect(x: Double(i) * p, y: ys[2], width: p, height: hs[2]), .letter) }
            let r3 = Array(symbolRows[2]), q = 8.5 * p / Double(r3.count)
            for (i, c) in r3.enumerated() { add(String(c), CGRect(x: Double(i) * q, y: ys[3], width: q, height: hs[3]), .letter) }
        } else {
            let r1 = Array(letterRows[0]), r2 = Array(letterRows[1]), r3 = Array(letterRows[2])
            for (i, c) in r1.enumerated() { add(String(c), CGRect(x: Double(i) * p, y: ys[1], width: p, height: hs[1]), .letter) }
            for (i, c) in r2.enumerated() {
                let x0 = i == 0 ? 0 : (Double(i) + 0.5) * p
                let x1 = i == r2.count - 1 ? W : (Double(i) + 1.5) * p
                add(String(c), CGRect(x: x0, y: ys[2], width: x1 - x0, height: hs[2]), .letter)
            }
            add("shift", CGRect(x: 0, y: ys[3], width: 1.5 * p, height: hs[3]), .special)
            for (i, c) in r3.enumerated() { add(String(c), CGRect(x: (Double(i) + 1.5) * p, y: ys[3], width: p, height: hs[3]), .letter) }
        }
        add("delete", CGRect(x: 8.5 * p, y: ys[3], width: W - 8.5 * p, height: hs[3]), .special)
        row(spec.bottom.filter { globe || $0.id != "globe" }, y: ys[4], h: hs[4], kind: .special)
        // v2: the row-3 / bottom-row line moves down by `split` (drawn) and `favour` more (hit); row 3 keeps its drawn size
        let sp = spec.split, fv = spec.split > 0 ? spec.favour : 0
        keys = keys.map { k in
            if abs(k.hit.minY - ys[3]) < 0.01 {
                return KeySlot(id: k.id, hit: CGRect(x: k.hit.minX, y: k.hit.minY, width: k.hit.width, height: k.hit.height + sp + fv),
                               visible: k.visible, kind: k.kind)
            }
            if abs(k.hit.minY - ys[4]) < 0.01 {
                return KeySlot(id: k.id, hit: CGRect(x: k.hit.minX, y: k.hit.minY + sp + fv, width: k.hit.width, height: k.hit.height - sp - fv),
                               visible: CGRect(x: k.visible.minX, y: k.visible.minY + sp, width: k.visible.width, height: k.visible.height - sp), kind: k.kind)
            }
            return k
        }
        // v2: return is an L; its part under backspace is drawn `drop` lower and the strip above it is dead
        let xd = 8.5 * p
        if spec.drop > 0, let i = keys.firstIndex(where: { $0.id == "return" }), keys[i].hit.minX < xd - p / 2 {
            let r = keys[i], v = r.visible
            keys[i] = KeySlot(id: r.id, hit: r.hit, visible: CGRect(x: v.minX, y: v.minY, width: xd - spec.gap / 2 - v.minX, height: v.height),
                              kind: r.kind, notch: CGRect(x: xd, y: r.hit.minY, width: W - xd, height: spec.drop - fv),
                              visible2: CGRect(x: xd + spec.gap / 2, y: v.minY + spec.drop, width: v.maxX - xd - spec.gap / 2, height: v.height - spec.drop))
        }
        // a and l: the tile reaches the screen edge, the drawn key keeps the normal width
        return keys.map { k in
            guard !symbols, k.id == "a" || k.id == "l" else { return k }
            let nw = p - spec.gap
            let v = k.visible
            let x = k.id == "a" ? v.maxX - nw : v.minX
            return KeySlot(id: k.id, hit: k.hit, visible: CGRect(x: x, y: v.minY, width: nw, height: v.height), kind: k.kind)
        }
    }

    static func visible(_ r: CGRect, W: Double, H: Double, spec: ComfortSpec) -> CGRect {
        let l = r.minX <= 0.01 ? spec.edge : spec.gap / 2
        let rt = r.maxX >= W - 0.01 ? spec.edge : spec.gap / 2
        let t = r.minY <= 0.01 ? spec.edge : spec.gap / 2
        let b = r.maxY >= H - 0.01 ? spec.edge : spec.gap / 2
        return CGRect(x: r.minX + l, y: r.minY + t - spec.lift, width: r.width - l - rt, height: r.height - t - b)
    }

    /// The key under a point, from the tiles (every point inside the keyboard maps to exactly one key, except
    /// return's moat under backspace, which maps to none). Points outside the keyboard go to the nearest tile.
    public static func key(at p: CGPoint, in keys: [KeySlot]) -> KeySlot? {
        if let k = keys.first(where: { $0.contains(p) }) { return k }
        if keys.contains(where: { $0.notch?.contains(p) ?? false }) { return nil }
        return keys.min { dist2($0.hit, p) < dist2($1.hit, p) }
    }

    static func dist2(_ r: CGRect, _ p: CGPoint) -> Double {
        let dx = max(r.minX - p.x, 0, p.x - r.maxX), dy = max(r.minY - p.y, 0, p.y - r.maxY)
        return Double(dx * dx + dy * dy)
    }
}
