import CoreGraphics
import Foundation

/// Where delete and return sit in a layout, and how much room each gets. Everything else (the action row, the letters
/// on Apple's grid, shift, 123, space) is the same in every layout.
public struct KeyShapeSpec: Equatable, Sendable {
    public enum Return: Sendable, Equatable {
        /// A reverse L (Tetris J) that owns the bottom-right corner: a foot on the bottom row (Apple's return, plus
        /// `footExtra`) and an arm in the corner above it, where Apple has delete.
        case corner
        /// The arm only: one tall key in the corner column, two rows high.
        case tall
        /// Apple's: the bottom row only.
        case flat
    }
    public enum Delete: Sendable, Equatable {
        /// On the bottom row, just left of the return.
        case besideReturn
        /// Apple's: at the end of the z row.
        case corner
        /// At the end of the a row, right after l; the a row moves half a key left to make room (2026-10-29).
        case afterL
    }
    public var ret: Return
    public var delete: Delete
    /// Drawn space on each side of delete on the bottom row (6 = the usual gap between keys). Delete's own tap area
    /// stays its key plus 3 pt; the rest of the room belongs to the neighbours, so a near miss never deletes.
    public var room: Double
    /// The return's foot is this much wider than Apple's return (points).
    public var footExtra: Double

    public init(ret: Return, delete: Delete, room: Double = 6, footExtra: Double = 0) {
        self.ret = ret; self.delete = delete; self.room = room; self.footExtra = footExtra
    }
}

public extension KeyLayoutKind {
    var shape: KeyShapeSpec {
        switch self {
        case .comfort: KeyShapeSpec(ret: .corner, delete: .besideReturn)
        case .roomy: KeyShapeSpec(ret: .corner, delete: .besideReturn, room: 14)
        case .bigReturn: KeyShapeSpec(ret: .corner, delete: .besideReturn, room: 14, footExtra: 24)
        case .tallReturn: KeyShapeSpec(ret: .tall, delete: .besideReturn, room: 14)
        case .deleteAfterL: KeyShapeSpec(ret: .corner, delete: .afterL)
        case .classic: KeyShapeSpec(ret: .flat, delete: .corner)
        }
    }
}

public extension KeyGeometry {
    /// Every layout on Apple's measured grid (Comfort v2's geometry, see `comfortV2`): letters, shift and 123 where
    /// Apple has them, Apple's hit rows (a row reaches to 1 pt above the next row's keys), the action row on top.
    /// Hit areas tile the whole keyboard, so a tap anywhere types the key under it. `.comfort` gives exactly
    /// `comfortV2` (unit test KeyLayoutsTests.testComfortIsV2).
    static func layout(_ kind: KeyLayoutKind, width W: Double, height H: Double, pointsPerMM ppm: Double, apple a: AppleKeyMetrics,
                       spec: ComfortSpec = .phone, globe: Bool = false, symbols: Bool = false, hand: KeyHand = .right,
                       page: KeyPage? = nil, field: KeyField = .text) -> [KeySlot] {
        let pg = page ?? (symbols ? .numbers : .letters)
        if pg.isPad {
            return padLayout(width: W, height: H, pointsPerMM: ppm, apple: a, spec: spec, globe: globe, hand: hand, page: pg, field: field)
        }
        let symbols = pg != .letters
        let s = kind.shape
        let P = a.pitch, cap = P - 6, gv = a.rowPitch - a.capHeight
        let m = W / 2 - 5 * P + 3                     // drawn left edge of q; p's drawn right edge is W - m
        func capTop(_ k: Int) -> Double { H - a.bottomGap - a.capHeight - Double(k) * a.rowPitch }
        func tileTop(_ k: Int) -> Double { k == 3 ? capTop(3) - gv / 2 : capTop(k) - 1 }
        func tileBottom(_ k: Int) -> Double { k == 0 ? H : capTop(k - 1) - 1 }
        var keys: [KeySlot] = []
        func add(_ id: String, _ t0: Double, _ t1: Double, row k: Int, _ d0: Double, _ d1: Double, _ kind: KeySlot.Kind) {
            keys.append(KeySlot(id: id, hit: CGRect(x: t0, y: tileTop(k), width: t1 - t0, height: tileBottom(k) - tileTop(k)),
                                visible: CGRect(x: d0, y: capTop(k), width: d1 - d0, height: a.capHeight), kind: kind))
        }
        // action row: v1's split of the width (hide, style, Dictate), from the top edge down to the q row
        let top = tileTop(3)
        for k in comfort(width: W, height: H, pointsPerMM: ppm, spec: spec, globe: globe, symbols: symbols, hand: hand) where k.kind == .action {
            keys.append(KeySlot(id: k.id, hit: CGRect(x: k.hit.minX, y: 0, width: k.hit.width, height: top),
                                visible: CGRect(x: k.visible.minX, y: spec.edge, width: k.visible.width, height: top - gv / 2 - spec.edge), kind: .action))
        }
        func centres(_ n: Int, shift: Double = 0) -> [Double] { (0..<n).map { W / 2 + (Double($0) - Double(n - 1) / 2) * P - shift } }
        // q row
        let r1 = Array(pg.rows[0]), c1 = centres(r1.count)
        for (i, c) in r1.enumerated() {
            add(String(c), i == 0 ? 0 : c1[i] - P / 2, i == r1.count - 1 ? W : c1[i] + P / 2, row: 3, c1[i] - cap / 2, c1[i] + cap / 2, .letter)
        }
        // a row; with delete after l the row moves half a key left (its keys line up under q..o) and delete takes p's column
        let afterL = s.delete == .afterL
        let sym2 = Array(pg.rows[1])
        let r2: [Character] = symbols && afterL ? Array(sym2.prefix(9)) : sym2
        let c2 = centres(r2.count, shift: afterL && !symbols ? P / 2 : 0)
        let c2v = afterL && symbols ? centres(10).prefix(9).map { $0 } : c2
        // L4: delete's tap area reaches Apple's 44 pt (2026-10-30; 402 pt phones had 42.9) by moving the a row's tap
        // boundaries up to 2.5 pt left. Each boundary stays inside the 6 pt gap between drawn keys, at least 0.5 pt from
        // both; the drawn keys and every letter's tap width (a full pitch) are unchanged, and a's tap area gives the room.
        let hs = afterL ? min(max(0, 44 - (W - ((c2v.last ?? W) + P / 2))), (P - cap) / 2 - 0.5) : 0
        for (i, c) in r2.enumerated() {
            let last = i == r2.count - 1
            add(String(c), i == 0 ? 0 : c2v[i] - P / 2 - hs, last && !afterL ? W : c2v[i] + P / 2 - hs, row: 2, c2v[i] - cap / 2, c2v[i] + cap / 2, .letter)
        }
        if afterL, let lc = c2v.last {
            add("delete", lc + P / 2 - hs, W, row: 2, lc + cap / 2 + 6, W - m, .special)
        }
        // z row: shift, z..m, then the corner (return's arm, or Apple's delete)
        let zc = centres(7)
        let zl = zc[0] - cap / 2, ml = zc[6] + cap / 2
        let cornerL = W - m - a.deleteWidth
        let b1 = (zl - a.edgeGap + zl) / 2, b2 = (ml + cornerL) / 2
        if symbols {
            // Apple's 123 and #+= pages: the page key (#+= or 123) where shift is, then . , ? ! ' sharing z to m. With
            // delete after l, the a row's tenth symbol (" or •) moves down to this row.
            add("more", 0, b1, row: 1, m, zl - a.edgeGap, .special)
            punctuationRow(Array(pg.rows[2]) + (afterL ? [sym2[9]] : []), b1: b1, b2: b2, zl: zl, ml: ml, add: add)
        } else {
            add("shift", 0, b1, row: 1, m, zl - a.edgeGap, .special)
            for (i, c) in Array(letterRows[2]).enumerated() {
                add(String(c), i == 0 ? b1 : zc[i] - P / 2, i == 6 ? b2 : zc[i] + P / 2, row: 1, zc[i] - cap / 2, zc[i] + cap / 2, .letter)
            }
        }
        if s.delete == .corner { add("delete", b2, W, row: 1, cornerL, W - m, .special) }
        // bottom row: 123, globe (home-button iPhones), space, delete (when it sits there), then return
        let retL = s.ret == .tall ? cornerL : W - m - a.returnWidth - s.footExtra   // drawn left of the return on the bottom row
        add("abc123", 0, m + a.abc123 + 3, row: 0, m, m + a.abc123, .special)
        var x = m + a.abc123 + 6
        if globe { add("globe", x - 3, x + a.abc123 + 3, row: 0, x, x + a.abc123, .special); x += a.abc123 + 6 }
        let retHitL: Double
        if s.delete == .besideReturn {
            let delR = retL - s.room, delL = delR - a.deleteWidth
            spaceAndExtras(field, from: x, drawnEnd: delL - s.room, hitEnd: delL - 3, extraWidth: a.abc123, add: add)
            add("delete", delL - 3, delR + 3, row: 0, delL, delR, .special)
            retHitL = delR + 3
        } else {
            spaceAndExtras(field, from: x, drawnEnd: retL - 6, hitEnd: retL - 3, extraWidth: a.abc123, add: add)
            retHitL = retL - 3
        }
        let rTop = tileTop(1)
        switch s.ret {
        case .corner, .tall:
            // one key: the hit area covers the z row from b2 and the bottom row from retHitL. The part of the box left
            // of the farther of the two is cut out (notch): the letters' in the z row, or delete's on the bottom row.
            let x0 = min(retHitL, b2)
            let arm = CGRect(x: cornerL, y: capTop(1), width: W - m - cornerL, height: capTop(0) + a.capHeight - capTop(1))
            let notch: CGRect? = b2 > retHitL ? CGRect(x: x0, y: rTop, width: b2 - x0, height: tileBottom(1) - rTop)
                : retHitL > b2 ? CGRect(x: x0, y: tileTop(0), width: retHitL - x0, height: H - tileTop(0)) : nil
            keys.append(KeySlot(id: "return",
                                hit: CGRect(x: x0, y: rTop, width: W - x0, height: H - rTop),
                                visible: arm,
                                kind: .special,
                                notch: notch,
                                visible2: s.ret == .corner ? CGRect(x: retL, y: capTop(0), width: W - m - retL, height: a.capHeight) : nil))
        case .flat:
            add("return", retHitL, W, row: 0, retL, W - m, .special)
        }
        return keys
    }
}

public extension KeyGeometry {
    typealias AddKey = (_ id: String, _ t0: Double, _ t1: Double, _ row: Int, _ d0: Double, _ d1: Double, _ kind: KeySlot.Kind) -> Void

    /// The z row's punctuation on the 123 and #+= pages, as Apple draws it: the keys share the room from z's left edge
    /// to m's right edge with the usual 6 pt gaps; the tap areas tile from the page key (b1) to the corner key (b2).
    static func punctuationRow(_ chars: [Character], b1: Double, b2: Double, zl: Double, ml: Double,
                               add: (String, Double, Double, Int, Double, Double, KeySlot.Kind) -> Void) {
        let n = Double(chars.count), w = (ml - zl - 6 * (n - 1)) / n
        for (i, c) in chars.enumerated() {
            let d0 = zl + Double(i) * (w + 6), d1 = d0 + w
            add(String(c), i == 0 ? b1 : d0 - 3, i == chars.count - 1 ? b2 : d1 + 3, 1, d0, d1, .letter)
        }
    }

    /// The bottom row between 123 (and the globe) and the key after space: space, then the keys Apple adds for this
    /// field (email @ and ., twitter @ and #, web search .), each as wide as 123; a URL field has no space, and its
    /// . / .com share the room equally (iOS 27.2: 69 pt each on the iPhone Air). Extra keys have ids "bx:<text>" so they never clash with the page's own keys.
    static func spaceAndExtras(_ field: KeyField, from x: Double, drawnEnd e: Double, hitEnd h: Double, extraWidth ew: Double,
                               add: (String, Double, Double, Int, Double, Double, KeySlot.Kind) -> Void) {
        let extras = field.bottomExtras
        if extras.isEmpty { add("space", x - 3, h, 0, x, e, .special); return }
        if field.hasSpace {
            var right = e
            var placed: [(id: String, d0: Double, d1: Double)] = []
            for id in extras.reversed() { placed.insert((id, right - ew, right), at: 0); right -= ew + 6 }
            add("space", x - 3, right + 3, 0, x, right, .special)
            for (i, p) in placed.enumerated() {
                add("bx:" + p.id, p.d0 - 3, i == placed.count - 1 ? h : p.d1 + 3, 0, p.d0, p.d1, .letter)
            }
        } else {
            let weights = extras.map { _ in 1.0 }
            let unit = (e - x - 6 * Double(extras.count - 1)) / weights.reduce(0, +)
            var d0 = x
            for (i, id) in extras.enumerated() {
                let w = unit * weights[i]
                add("bx:" + id, i == 0 ? x - 3 : d0 - 3, i == extras.count - 1 ? h : d0 + w + 3, 0, d0, d0 + w, .letter)
                d0 += w + 6
            }
        }
    }

    /// Number, decimal and phone fields: the Dictate row on top, then 1 to 9 in a grid of three on Apple's rows, and a
    /// bottom row of (decimal point, the phone pad's +*# key, or nothing), 0 and delete.
    static func padLayout(width W: Double, height H: Double, pointsPerMM ppm: Double, apple a: AppleKeyMetrics, spec: ComfortSpec,
                          globe: Bool, hand: KeyHand, page: KeyPage, field: KeyField) -> [KeySlot] {
        let P = a.pitch, gv = a.rowPitch - a.capHeight
        let m = W / 2 - 5 * P + 3
        func capTop(_ k: Int) -> Double { H - a.bottomGap - a.capHeight - Double(k) * a.rowPitch }
        func tileTop(_ k: Int) -> Double { k == 3 ? capTop(3) - gv / 2 : capTop(k) - 1 }
        func tileBottom(_ k: Int) -> Double { k == 0 ? H : capTop(k - 1) - 1 }
        var keys: [KeySlot] = []
        let top = tileTop(3)
        for k in comfort(width: W, height: H, pointsPerMM: ppm, spec: spec, globe: globe, symbols: true, hand: hand) where k.kind == .action {
            keys.append(KeySlot(id: k.id, hit: CGRect(x: k.hit.minX, y: 0, width: k.hit.width, height: top),
                                visible: CGRect(x: k.visible.minX, y: spec.edge, width: k.visible.width, height: top - gv / 2 - spec.edge), kind: .action))
        }
        let cw = (W - 2 * m - 12) / 3
        func add(_ id: String, col j: Int, row k: Int, _ kind: KeySlot.Kind) {
            let d0 = m + Double(j) * (cw + 6), d1 = d0 + cw
            let t0 = j == 0 ? 0 : d0 - 3, t1 = j == 2 ? W : d1 + 3
            keys.append(KeySlot(id: id, hit: CGRect(x: t0, y: tileTop(k), width: t1 - t0, height: tileBottom(k) - tileTop(k)),
                                visible: CGRect(x: d0, y: capTop(k), width: cw, height: a.capHeight), kind: kind))
        }
        let grid = page == .padSymbols ? [["+", "*", "#"], ["(", ")", "-"], [",", ";", "/"]]
            : [["1", "2", "3"], ["4", "5", "6"], ["7", "8", "9"]]
        for (r, row) in grid.enumerated() { for (j, id) in row.enumerated() { add(id, col: j, row: 3 - r, .letter) } }
        switch field {
        case .decimalPad: add(".", col: 0, row: 0, .letter)
        case .phonePad: add("padmore", col: 0, row: 0, .special)
        default: add("blank", col: 0, row: 0, .special)
        }
        add("0", col: 1, row: 0, .letter)
        add("delete", col: 2, row: 0, .special)
        return keys
    }
}

/// Which geometry and size the keyboard uses on this device: the app's Settings preview and the keyboard extension
/// call the same code, so the preview is the keyboard.
public enum KeyboardLayouts {
    /// Apple's key metrics for this width. iPhone: measured per size (AppleKeyMetrics.measured). iPad: Apple's iPad
    /// keyboard has another shape (11 columns), so our layouts keep the iPhone arrangement with Apple's iPad key height
    /// and row pitch, and the letter pitch that fills the width the way the iPhone grid does (AppleKeyMetrics.iPad).
    /// By the width the keyboard really gets: the iPad's floating keyboard (about 320 pt) gets the iPhone metrics for
    /// that width (for accessibility); the panel density (pointsPerMM) stays the device's.
    public static func metrics(width: Double, isPad: Bool) -> AppleKeyMetrics {
        usesPadMetrics(width: width, isPad: isPad) ? AppleKeyMetrics.iPad(width: width) : AppleKeyMetrics.forWidth(width)
    }

    /// iPad metrics from this width up: the narrowest docked iPad keyboard is 744 pt (iPad mini), the widest iPhone
    /// 440 pt, the floating iPad keyboard about 320 pt.
    public static let padMinWidth: Double = 500

    public static func usesPadMetrics(width: Double, isPad: Bool) -> Bool { isPad && width >= padMinWidth }

    /// Keyboard view height: the action row stays 54 pt tall over the four key rows.
    public static func height(width: Double, isPad: Bool) -> Double {
        width < 1 ? 280 : metrics(width: width, isPad: isPad).viewHeight
    }

    /// iOS does not report the panel density, so use the device class: 3x iPhones are 460 ppi, 2x iPhones 326 ppi,
    /// iPads 264 ppi.
    public static func pointsPerMM(scale: Double, isPad: Bool) -> Double {
        if isPad { return KeyGeometry.pointsPerMM(ppi: 264, scale: scale) }
        return KeyGeometry.pointsPerMM(ppi: scale >= 3 ? 460 : 326, scale: scale)
    }

    public static func keys(_ kind: KeyLayoutKind, width: Double, height: Double, isPad: Bool, scale: Double,
                            globe: Bool = false, symbols: Bool = false, hand: KeyHand = .right,
                            page: KeyPage? = nil, field: KeyField = .text, styleKey: Bool = true) -> [KeySlot] {
        KeyGeometry.layout(kind, width: width, height: height, pointsPerMM: pointsPerMM(scale: scale, isPad: isPad),
                           apple: metrics(width: width, isPad: isPad), spec: .keyboard(styleKey: styleKey || isPad), globe: globe, symbols: symbols,
                           hand: hand, page: page, field: field).withoutStyleKey(!styleKey && isPad)
    }
}

public extension Array where Element == KeySlot {
    /// Build 38 (iPad on 37: the hide key did not get wider, Dictate got a lot longer): on iPad, without
    /// the style key, the hide key takes the style key's place and the gap between them; Dictate keeps the exact frame
    /// it has with the style key. Every other key is untouched. iPhone keeps build 37's row (ComfortSpec.phoneNoStyle).
    func withoutStyleKey(_ remove: Bool) -> [KeySlot] {
        guard remove, let s = first(where: { $0.id == "style" }), let h = first(where: { $0.id == "hide" }) else { return self }
        let wide = KeySlot(id: "hide", hit: h.hit.union(s.hit), visible: h.visible.union(s.visible), kind: h.kind, notch: h.notch, visible2: h.visible2)
        return compactMap { $0.id == "style" ? nil : ($0.id == "hide" ? wide : $0) }
    }
}
