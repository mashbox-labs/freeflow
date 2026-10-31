import XCTest
import CoreGraphics
@testable import FreeFlowKit

/// About four more bar heights in the listening view, keyboard and app (2026-10-30).
final class WaveformStepsTests: XCTestCase {
    // Keyboard: 32 bars, iPhone Air keyboard 420 pt wide less 3 pt padding each side; app: 40 bars in a 370 pt card.
    func testKeyboardGainsFourHeights() {
        let w = WaveformView.barWidth(width: 414, count: 32)
        let before = WaveformView.heightsBuild10(height: 64, barWidth: w)
        let after = WaveformView.heights(height: 64, barWidth: w)
        print("WAVESTEPS keyboard bar=\(w) before=\(before) after=\(after)")
        XCTAssertGreaterThanOrEqual(after - before, 4)
    }

    func testAppGainsFourHeights() {
        let w = WaveformView.barWidth(width: 370, count: 40)
        let before = WaveformView.heightsBuild10(height: 64, barWidth: w)
        let after = WaveformView.heights(height: 64, barWidth: w)
        print("WAVESTEPS app bar=\(w) before=\(before) after=\(after)")
        XCTAssertGreaterThanOrEqual(after - before, 4)
    }

    func testEveryWidthGainsFourAndFullLevelFillsTheMeter() {
        for width in stride(from: CGFloat(300), through: 1000, by: 7) {
            for count in [32, 40] {
                let w = WaveformView.barWidth(width: width, count: count)
                let step = WaveformView.step(height: 64, barWidth: w)
                XCTAssertGreaterThanOrEqual(WaveformView.heights(height: 64, barWidth: w) - WaveformView.heightsBuild10(height: 64, barWidth: w), 4)
                XCTAssertEqual((64 / step).rounded() * step, 64, accuracy: 0.001)
            }
        }
    }
}
