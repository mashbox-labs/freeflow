import AppKit

/// The floating pill near the bottom centre of the screen you are working on, over every app and full-screen space,
/// drawn in AppKit (the plug-in can't use SwiftUI inside a Catalyst app). The same pill as build 19 (Mac/Pill.swift): a
/// dark capsule (MASHBOX ink, the same in light and dark) with a full thin stroke and ember bars that move with your
/// voice, from the middle out; hands-free adds cancel and stop; a slow wave while it writes; a short line for messages.
/// It never takes focus from the app you are dictating into (a non-activating panel) and takes clicks only in hands-free.
@MainActor
final class PillPanel {
    enum Look: Equatable { case listening, handsFree, working, message(String) }

    static let size = NSSize(width: 340, height: 64)
    var onStop: (() -> Void)?
    var onCancel: (() -> Void)?
    private var panel: NSPanel?
    private let canvas = PillCanvas(frame: NSRect(origin: .zero, size: PillPanel.size))
    private var hideWork: DispatchWorkItem?
    private var visible = false

    init() {
        canvas.onStop = { [weak self] in self?.onStop?() }
        canvas.onCancel = { [weak self] in self?.onCancel?() }
    }

    func show(_ look: Look) {
        hideWork?.cancel()
        let panel = self.panel ?? makePanel()
        if !visible { place(panel); panel.alphaValue = 0 }
        if look == .listening || look == .handsFree, canvas.look != .listening, canvas.look != .handsFree { canvas.clearLevels() }
        canvas.look = look
        panel.ignoresMouseEvents = look != .handsFree
        panel.orderFrontRegardless()
        if !visible {
            visible = true
            NSAnimationContext.runAnimationGroup { $0.duration = 0.18; panel.animator().alphaValue = 1 }
        }
    }

    func hide() {
        hideWork?.cancel()
        guard visible, let panel else { return }
        visible = false
        canvas.look = .listening
        NSAnimationContext.runAnimationGroup({ $0.duration = 0.16; panel.animator().alphaValue = 0 }) { [weak self] in
            MainActor.assumeIsolated { if self?.visible == false { panel.orderOut(nil) } }
        }
    }

    /// A short line in the pill, gone after a moment.
    func flash(_ text: String, seconds: Double) {
        show(.message(text))
        let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.hide() } }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    func push(_ level: Float) { canvas.push(level) }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: Self.size),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isMovable = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.ignoresMouseEvents = true
        panel.contentView = canvas
        self.panel = panel
        return panel
    }

    /// Bottom centre of the screen with the window you are typing in (else the one with the pointer), above the Dock.
    private func place(_ panel: NSPanel) {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.main ?? NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.screens.first
        guard let frame = screen?.visibleFrame else { return }
        panel.setFrameOrigin(NSPoint(x: frame.midX - Self.size.width / 2, y: frame.minY + 10))
    }
}

/// Draws the pill. Sizes and colours are build 19's (Mac/Pill.swift PillView).
final class PillCanvas: NSView {
    static let ink = NSColor(srgbRed: 0x0B / 255, green: 0x0A / 255, blue: 0x09 / 255, alpha: 1)
    static let bone = NSColor(srgbRed: 0xEC / 255, green: 0xE6 / 255, blue: 0xDA / 255, alpha: 1)
    static let ember = NSColor(srgbRed: 0xFF / 255, green: 0x5A / 255, blue: 0x1F / 255, alpha: 1)
    static let emberInk = NSColor(srgbRed: 0x1A / 255, green: 0x0B / 255, blue: 0x04 / 255, alpha: 1)
    static let bars = 15, history = 8
    static let barWidth: CGFloat = 3, barGap: CGFloat = 2.5, barMin: CGFloat = 3, barMax: CGFloat = 20
    /// How tall each distance from the middle can go (the middle bar first): a soft hump like a voice.
    static let shape: [CGFloat] = [1, 0.94, 0.86, 0.76, 0.64, 0.52, 0.42, 0.34]

    var look: PillPanel.Look = .listening { didSet { if look != oldValue { updateTimer(); needsDisplay = true } } }
    var onStop: (() -> Void)?
    var onCancel: (() -> Void)?
    /// Recent mic levels 0...1, newest first; shown from the middle out.
    private var levels = [Float](repeating: 0, count: PillCanvas.history)
    private var timer: Timer?
    private var cancelRect = NSRect.zero, stopRect = NSRect.zero

    override var isFlipped: Bool { false }

    func push(_ level: Float) {
        levels.removeLast()
        levels.insert(level, at: 0)
        if look == .listening || look == .handsFree { needsDisplay = true }
    }

    func clearLevels() { levels = [Float](repeating: 0, count: Self.history) }

    /// The writing wave runs at 30 frames a second only while it is shown (still with Reduce Motion).
    private func updateTimer() {
        timer?.invalidate(); timer = nil
        guard look == .working, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        let t = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in self?.needsDisplay = true }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private var liveWidth: CGFloat { CGFloat(Self.bars) * Self.barWidth + CGFloat(Self.bars - 1) * Self.barGap }

    private func font() -> NSFont {
        let base = NSFont(name: "Outfit", size: 13) ?? NSFont.systemFont(ofSize: 13, weight: .medium)
        return NSFontManager.shared.convert(base, toHaveTrait: []).withWeight(.medium)
    }

    override func draw(_ dirtyRect: NSRect) {
        let height: CGFloat = look == .handsFree ? 36 : 32
        let text = NSAttributedString(string: { if case .message(let s) = look { return s } else { return "" } }(),
                                      attributes: [.font: font(), .foregroundColor: Self.bone])
        let contentWidth: CGFloat
        let padding: CGFloat
        switch look {
        case .listening: contentWidth = liveWidth; padding = 13
        case .handsFree: contentWidth = 24 + 10 + liveWidth + 10 + 24; padding = 6
        case .working: contentWidth = 7 * Self.barWidth + 6 * Self.barGap; padding = 13
        case .message: contentWidth = min(ceil(text.size().width), bounds.width - 40); padding = 14
        }
        let width = contentWidth + 2 * padding
        let capsule = NSRect(x: (bounds.width - width) / 2, y: 12, width: width, height: height)
        // Shadow, fill, then the full thin stroke.
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
        shadow.shadowBlurRadius = 10
        shadow.shadowOffset = NSSize(width: 0, height: -4)
        shadow.set()
        Self.ink.withAlphaComponent(0.94).setFill()
        NSBezierPath(roundedRect: capsule, xRadius: height / 2, yRadius: height / 2).fill()
        NSGraphicsContext.restoreGraphicsState()
        let stroke = NSBezierPath(roundedRect: capsule.insetBy(dx: 0.5, dy: 0.5), xRadius: height / 2 - 0.5, yRadius: height / 2 - 0.5)
        stroke.lineWidth = 1
        Self.bone.withAlphaComponent(0.16).setStroke()
        stroke.stroke()

        let midY = capsule.midY
        var x = capsule.minX + padding
        switch look {
        case .listening:
            drawLive(x: x, midY: midY)
        case .handsFree:
            cancelRect = NSRect(x: x, y: midY - 12, width: 24, height: 24)
            drawButton(cancelRect, symbol: "xmark", ember: false)
            x += 24 + 10
            drawLive(x: x, midY: midY)
            x += liveWidth + 10
            stopRect = NSRect(x: x, y: midY - 12, width: 24, height: 24)
            drawButton(stopRect, symbol: "stop.fill", ember: true)
        case .working:
            let t = Date().timeIntervalSinceReferenceDate
            let still = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            for i in 0..<7 {
                let wave = still ? 0 : (sin(t * 5 - Double(i) * 0.8) + 1) / 2
                let h = Self.barMin + 7 * CGFloat(wave)
                Self.ember.withAlphaComponent(0.55 + 0.45 * wave).setFill()
                bar(x: x, midY: midY, height: h)
                x += Self.barWidth + Self.barGap
            }
        case .message:
            let size = text.size()
            text.draw(with: NSRect(x: x, y: midY - size.height / 2, width: contentWidth, height: size.height),
                      options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        }
    }

    private func drawLive(x start: CGFloat, midY: CGFloat) {
        var x = start
        Self.ember.setFill()
        for i in 0..<Self.bars {
            let d = abs(i - Self.bars / 2)
            let level = CGFloat(d < levels.count ? levels[d] : 0)
            let shape = Self.shape[min(d, Self.shape.count - 1)]
            bar(x: x, midY: midY, height: Self.barMin + (Self.barMax - Self.barMin) * level * shape)
            x += Self.barWidth + Self.barGap
        }
    }

    private func bar(x: CGFloat, midY: CGFloat, height: CGFloat) {
        let r = NSRect(x: x, y: midY - height / 2, width: Self.barWidth, height: height)
        NSBezierPath(roundedRect: r, xRadius: Self.barWidth / 2, yRadius: Self.barWidth / 2).fill()
    }

    private func drawButton(_ rect: NSRect, symbol: String, ember: Bool) {
        (ember ? Self.ember : Self.bone.withAlphaComponent(0.14)).setFill()
        NSBezierPath(ovalIn: rect).fill()
        let config = NSImage.SymbolConfiguration(pointSize: ember ? 9 : 10, weight: .bold)
            .applying(.init(paletteColors: [ember ? Self.emberInk : Self.bone]))
        guard let image = NSImage(systemSymbolName: symbol, accessibilityDescription: ember ? "Stop and type" : "Cancel")?
            .withSymbolConfiguration(config) else { return }
        let s = image.size
        image.draw(in: NSRect(x: rect.midX - s.width / 2, y: rect.midY - s.height / 2, width: s.width, height: s.height))
    }

    override func mouseDown(with event: NSEvent) {
        guard look == .handsFree else { return }
        let p = convert(event.locationInWindow, from: nil)
        if cancelRect.insetBy(dx: -4, dy: -4).contains(p) { onCancel?() }
        else if stopRect.insetBy(dx: -4, dy: -4).contains(p) { onStop?() }
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

private extension NSFont {
    func withWeight(_ weight: NSFont.Weight) -> NSFont {
        let d = fontDescriptor.addingAttributes([.traits: [NSFontDescriptor.TraitKey.weight: weight]])
        return NSFont(descriptor: d, size: pointSize) ?? self
    }
}
