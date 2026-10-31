import SwiftUI

/// Live level bars, drawn as stepped pixel blocks (the mashbox.gg homepage's 8-bit accent).
/// `levels` are 0...1, newest last.
public struct WaveformView: View {
    let levels: [Float]
    let color: Color
    public init(levels: [Float], color: Color = Palette.brand) {
        self.levels = levels
        self.color = color
    }

    public var body: some View {
        GeometryReader { geo in
            let count = max(levels.count, 1)
            let gap: CGFloat = 3
            let w = Self.barWidth(width: geo.size.width, count: count, gap: gap)
            let step = Self.step(height: geo.size.height, barWidth: w)
            HStack(alignment: .center, spacing: gap) {
                ForEach(Array(levels.enumerated()), id: \.offset) { _, level in
                    let blocks = max(1, (CGFloat(level) * geo.size.height / step).rounded())
                    Rectangle()
                        .fill(color)
                        .frame(width: w, height: blocks * step)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .animation(.linear(duration: 0.08), value: levels)
        }
        .accessibilityIdentifier("waveform")
        .accessibilityLabel("Live audio level")
    }

    /// Build 10 (2026-10-30) needed at least four more bar heights.
    /// Build 10 drew square steps (step = bar width, at least 4 pt): 6 heights in the keyboard's 64 pt (32 bars) and
    /// about 10 in the app's (40 bars). The same height now holds `extraSteps` more steps. Same bars, same redraws
    /// (LevelFeed decides those); only how finely a level is cut changes.
    public static let extraSteps: CGFloat = 4

    /// The height of one step for bars this wide in a meter this tall.
    public static func step(height: CGFloat, barWidth: CGFloat) -> CGFloat {
        let square = max(4, barWidth)
        let steps = max(1, (height / square).rounded()) + extraSteps
        return height / steps
    }

    /// How many different bar heights the meter can show (the shortest bar is one step).
    public static func heights(height: CGFloat, barWidth: CGFloat) -> Int {
        Int((height / step(height: height, barWidth: barWidth)).rounded())
    }

    /// Build 10's count, for the tests.
    static func heightsBuild10(height: CGFloat, barWidth: CGFloat) -> Int { Int((height / max(4, barWidth)).rounded()) }

    public static func barWidth(width: CGFloat, count: Int, gap: CGFloat = 3) -> CGFloat {
        max(2, (width - gap * CGFloat(max(count, 1) - 1)) / CGFloat(max(count, 1)))
    }
}

public enum Levels {
    /// Maps RMS to 0...1 on a dB scale (-55 dB -> 0, -10 dB -> 1).
    public static func normalise(rms: Float) -> Float {
        let db = 20 * log10(max(rms, 1e-7))
        return min(1, max(0, (db + 55) / 45))
    }
}

/// The listening bars' level (2026-10-30: more range and reactivity in the bars, kept lightweight on the
/// CPU). The same RMS as
/// before, only remapped: dB with a noise floor at -50 dB (room noise stays at the bottom), an expansion curve (x^1.6)
/// so quiet speech sits low and loud speech reaches the top (-40 dB -> 0.12, -25 dB -> 0.51, -15 dB -> 0.88; the old
/// straight map, `Levels.normalise`, gave 0.33, 0.67, 0.89), and a fast attack / slower release per audio chunk
/// (~43 ms) so the bars jump with the voice and fall back smoothly. A few multiplies per chunk: no new audio
/// processing, and how often the bars redraw is unchanged (LevelFeed).
public struct LevelShaper {
    public static let floorDB: Float = -50, topDB: Float = -12, expansion: Float = 1.6
    public static let attack: Float = 0.7, release: Float = 0.2
    public private(set) var level: Float = 0

    public init() {}

    /// 0...1 for an RMS, before attack / release.
    public static func target(rms: Float) -> Float {
        let db = 20 * log10(max(rms, 1e-7))
        let x = min(1, max(0, (db - floorDB) / (topDB - floorDB)))
        return pow(x, expansion)
    }

    public mutating func next(rms: Float) -> Float {
        let t = Self.target(rms: rms)
        level += (t - level) * (t > level ? Self.attack : Self.release)
        return level
    }
}
