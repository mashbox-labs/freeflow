import CoreGraphics
import Foundation

/// Apple's English iPhone keyboard, measured from its drawn keys in the iOS 26.5 simulator (2026-10-29). Its letter
/// rows are a grid centred on the screen: key i of an n-key row sits at width / 2 + (i - (n - 1) / 2) * pitch, drawn
/// pitch - 6 wide, and the rows sit `rowPitch` apart counted up from the bottom row.
public struct AppleKeyMetrics: Equatable, Sendable {
    public let width: Double        // screen width measured on, points
    public let pitch: Double        // letter centre to centre
    public let capHeight: Double    // drawn key height
    public let rowPitch: Double     // row centre to row centre
    public let bottomGap: Double    // bottom row's drawn bottom to the bottom of the keyboard view
    public let abc123: Double       // drawn widths
    public let returnWidth: Double
    public let deleteWidth: Double
    public let edgeGap: Double      // drawn gap shift to z, and m to the key at the end of the row

    public init(width: Double, pitch: Double, capHeight: Double, rowPitch: Double, bottomGap: Double, abc123: Double,
                returnWidth: Double, deleteWidth: Double, edgeGap: Double) {
        self.width = width; self.pitch = pitch; self.capHeight = capHeight; self.rowPitch = rowPitch; self.bottomGap = bottomGap
        self.abc123 = abc123; self.returnWidth = returnWidth; self.deleteWidth = deleteWidth; self.edgeGap = edgeGap
    }

    /// Measured: iPhone 17 / 17 Pro (402 x 874), iPhone Air (420 x 912), iPhone 17 Pro Max (440 x 956). Apple's 123 key is
    /// its width with the emoji key beside it (Air measured; the others scaled by pitch), so space keeps Apple's size.
    /// bottomGap: our keyboard view ends 75 pt above the screen bottom (measured on the Air; assumed on the others).
    public static let measured: [AppleKeyMetrics] = [
        AppleKeyMetrics(width: 402, pitch: 39.533, capHeight: 43, rowPitch: 54, bottomGap: 3, abc123: 43.36,
                        returnWidth: 93.0, deleteWidth: 45.67, edgeGap: 13.67),
        AppleKeyMetrics(width: 420, pitch: 41.333, capHeight: 45, rowPitch: 56, bottomGap: 5, abc123: 45.33,
                        returnWidth: 97.33, deleteWidth: 48.0, edgeGap: 14.0),
        AppleKeyMetrics(width: 440, pitch: 43.333, capHeight: 45, rowPitch: 56, bottomGap: 5, abc123: 47.53,
                        returnWidth: 102.33, deleteWidth: 50.33, edgeGap: 14.67),
    ]

    /// The set measured at this width, else the nearest measured set with its pitch scaled to the width.
    public static func forWidth(_ w: Double) -> AppleKeyMetrics {
        if let m = measured.first(where: { abs($0.width - w) < 0.5 }) { return m }
        let n = measured.min { abs($0.width - w) < abs($1.width - w) }!
        let s = w / n.width
        return AppleKeyMetrics(width: w, pitch: n.pitch * s, capHeight: n.capHeight, rowPitch: n.rowPitch, bottomGap: n.bottomGap,
                               abc123: n.abc123 * s, returnWidth: n.returnWidth * s, deleteWidth: n.deleteWidth * s, edgeGap: n.edgeGap)
    }

    /// The keyboard view height that keeps the action row (hide, style, Dictate) 54 pt tall over Apple's four rows.
    public var viewHeight: Double { 3 + 54 + (rowPitch - capHeight) + 3 * rowPitch + capHeight + bottomGap }
}

public extension KeyGeometry {
    /// Comfort v2 (2026-10-29): letters, shift, 123 and space where Apple's keyboard has them,
    /// so fingers find them where they expect; the action row (hide, style, Dictate) on top, as in v1; return is a
    /// reverse L (Tetris J) that owns the bottom-right corner: Apple's return on the bottom row plus the corner key
    /// above it, where Apple has delete. Delete moves down next to it, at Apple's size. Hit areas tile the whole
    /// keyboard (no dead gaps); the return's two arms are one key with one continuous hit area.
    static func comfortV2(width W: Double, height H: Double, pointsPerMM ppm: Double, apple a: AppleKeyMetrics,
                          spec: ComfortSpec = .phone, globe: Bool = false, symbols: Bool = false, hand: KeyHand = .right) -> [KeySlot] {
        let P = a.pitch, cap = P - 6, gv = a.rowPitch - a.capHeight
        let m = W / 2 - 5 * P + 3                     // drawn left edge of q; p's drawn right edge is W - m
        // rows counted from the bottom: 0 bottom row, 1 z row, 2 a row, 3 q row
        func capTop(_ k: Int) -> Double { H - a.bottomGap - a.capHeight - Double(k) * a.rowPitch }
        // Apple's hit rows (its accessibility cells, measured): a row reaches down to 1 pt above the next row's keys, so a
        // tap a little below a key is that key's (Air: M cell 730...786, M drawn 731...776). The q row's top edge
        // splits the gap to the action row evenly, so a tap just above q never starts dictation.
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
        func centres(_ n: Int) -> [Double] { (0..<n).map { W / 2 + (Double($0) - Double(n - 1) / 2) * P } }
        let upper = symbols ? [symbolRows[0], symbolRows[1]] : [letterRows[0], letterRows[1]]
        for (r, row) in upper.enumerated() {
            let chars = Array(row), cs = centres(chars.count)
            for (i, c) in chars.enumerated() {
                add(String(c), i == 0 ? 0 : cs[i] - P / 2, i == chars.count - 1 ? W : cs[i] + P / 2, row: 3 - r, cs[i] - cap / 2, cs[i] + cap / 2, .letter)
            }
        }
        // z row: shift, z..m, then return's upper arm in Apple's delete corner
        let zc = centres(7)
        let zl = zc[0] - cap / 2, ml = zc[6] + cap / 2
        let armL = W - m - a.deleteWidth
        let b1 = (zl - a.edgeGap + zl) / 2, b2 = (ml + armL) / 2
        if symbols {
            // Apple's 123 page: the #+= key where shift is, then . , ? ! ' sharing z to m (build 18)
            add("more", 0, b1, row: 1, m, zl - a.edgeGap, .special)
            punctuationRow(Array(symbolRows[2]), b1: b1, b2: b2, zl: zl, ml: ml, add: add)
        } else {
            add("shift", 0, b1, row: 1, m, zl - a.edgeGap, .special)
            for (i, c) in Array(letterRows[2]).enumerated() {
                add(String(c), i == 0 ? b1 : zc[i] - P / 2, i == 6 ? b2 : zc[i] + P / 2, row: 1, zc[i] - cap / 2, zc[i] + cap / 2, .letter)
            }
        }
        // bottom row: 123, globe (home-button iPhones), space, delete, then return's foot (Apple's return)
        let footL = W - m - a.returnWidth
        let delR = footL - 6, delL = delR - a.deleteWidth
        add("abc123", 0, m + a.abc123 + 3, row: 0, m, m + a.abc123, .special)
        var x = m + a.abc123 + 6
        if globe { add("globe", x - 3, x + a.abc123 + 3, row: 0, x, x + a.abc123, .special); x += a.abc123 + 6 }
        add("space", x - 3, delL - 3, row: 0, x, delL - 6, .special)
        add("delete", delL - 3, footL - 3, row: 0, delL, delR, .special)
        let rTop = tileTop(1)
        keys.append(KeySlot(id: "return",
                            hit: CGRect(x: footL - 3, y: rTop, width: W - footL + 3, height: H - rTop),
                            visible: CGRect(x: armL, y: capTop(1), width: W - m - armL, height: capTop(0) + a.capHeight - capTop(1)),
                            kind: .special,
                            notch: CGRect(x: footL - 3, y: rTop, width: b2 - footL + 3, height: tileBottom(1) - rTop),
                            visible2: CGRect(x: footL, y: capTop(0), width: W - m - footL, height: a.capHeight)))
        return keys
    }
}

public extension AppleKeyMetrics {
    /// Apple's iPad keyboard, measured on the iPad mini (A17 Pro) simulator, iOS 26.5, 744 x 1133 portrait
    /// (2026-10-29). Apple's iPad keyboard is another shape (11 columns, two
    /// shift keys, delete on the q row), so our layouts keep the iPhone arrangement and take from it only the key height,
    /// the row pitch, the margin to the screen edge and where the bottom row ends. Measured (drawn caps, pixels / 2):
    /// letter caps 54.5 x 55.5 on a 66.5 pitch, rows 64.5 apart (tops 856, 920.5, 985, 1049.5), q's left edge 6.0, the
    /// bottom row ending at y 1105; our keyboard view ends at y 1108 on that screen (the system strip below it is
    /// 22 pt), so the bottom row ends 3 pt above our view's bottom, as Apple's does.
    static let iPadMiniMeasured = (capHeight: 55.5, rowPitch: 64.5, qLeft: 6.0, bottomGap: 3.0)

    /// iPad: the iPhone grid stretched to the width (as build 5-8's iPad Comfort was: letters about a tenth of the width),
    /// Apple's iPad key height and row pitch. 123, return and delete keep their iPhone Air share of the letter pitch.
    static func iPad(width w: Double) -> AppleKeyMetrics {
        let m = iPadMiniMeasured, air = measured[1]
        let pitch = (w - 2 * (m.qLeft - 3)) / 10, s = pitch / air.pitch
        return AppleKeyMetrics(width: w, pitch: pitch, capHeight: m.capHeight, rowPitch: m.rowPitch, bottomGap: m.bottomGap,
                               abc123: air.abc123 * s, returnWidth: air.returnWidth * s, deleteWidth: air.deleteWidth * s, edgeGap: air.edgeGap * s)
    }
}
