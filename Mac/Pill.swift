import AppKit
import FreeFlowKit
import SwiftUI

/// What the pill shows.
enum PillLook: Equatable {
    case listening          // fn held: live audio bars
    case handsFree          // recording without fn held: bars plus cancel and stop
    case working            // transcribing and writing
    case message(String)    // one short line, then the pill goes away
}

@MainActor
final class PillModel: ObservableObject {
    static let history = 8
    @Published var look: PillLook = .listening
    @Published var visible = false
    /// Recent mic levels 0...1, newest first. The bars are drawn from the middle out, newest in the middle.
    @Published var levels: [Float] = Array(repeating: 0, count: PillModel.history)
    var onStop: (() -> Void)?
    var onCancel: (() -> Void)?

    func push(_ level: Float) {
        levels.removeLast()
        levels.insert(level, at: 0)
    }

    func clearLevels() { levels = Array(repeating: 0, count: Self.history) }
}

/// The floating pill near the bottom centre of the screen you are working on, over every app and full-screen space. It
/// never takes focus from the app you are dictating into (a non-activating panel); it takes clicks only in hands-free,
/// for its cancel and stop buttons.
@MainActor
final class PillController {
    let model = PillModel()
    private var panel: NSPanel?
    private var hideWork: DispatchWorkItem?
    static let size = NSSize(width: 340, height: 64)

    func show(_ look: PillLook) {
        hideWork?.cancel()
        let panel = self.panel ?? makePanel()
        if !model.visible { place(panel) }
        if look == .listening || look == .handsFree, model.look != .listening, model.look != .handsFree { model.clearLevels() }
        model.look = look
        panel.ignoresMouseEvents = look != .handsFree
        panel.orderFrontRegardless()
        withAnimation(.spring(response: 0.26, dampingFraction: 0.82)) { model.visible = true }
    }

    func hide() {
        hideWork?.cancel()
        withAnimation(.easeOut(duration: 0.16)) { model.visible = false }
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.model.visible else { return }
            self.panel?.orderOut(nil)
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.22, execute: work)
    }

    /// A short line in the pill, gone after a moment.
    func flash(_ text: String, seconds: Double = 2.4) {
        show(.message(text))
        let work = DispatchWorkItem { [weak self] in self?.hide() }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    func push(_ level: Float) { model.push(level) }

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
        let host = NSHostingView(rootView: PillView(model: model))
        host.frame = NSRect(origin: .zero, size: Self.size)
        panel.contentView = host
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

/// The pill: a dark capsule (MASHBOX ink, the same in light and dark) with a full thin stroke, and ember bars that move
/// with your voice, drawn from the middle out (newest level in the middle). Hands-free adds cancel and stop.
struct PillView: View {
    @ObservedObject var model: PillModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static let ink = Color(hex: 0x0B0A09)
    static let bone = Color(hex: 0xECE6DA)
    static let bars = 15
    static let barWidth: CGFloat = 3, barGap: CGFloat = 2.5, barMin: CGFloat = 3, barMax: CGFloat = 20
    /// How tall each distance from the middle can go (the middle bar first): a soft hump like a voice.
    static let shape: [CGFloat] = [1, 0.94, 0.86, 0.76, 0.64, 0.52, 0.42, 0.34]

    var body: some View {
        ZStack(alignment: .bottom) {
            Color.clear
            if model.visible {
                content
                    .padding(.horizontal, padding)
                    .frame(height: height)
                    .background(Self.ink.opacity(0.94), in: Capsule(style: .continuous))
                    .overlay(Capsule(style: .continuous).strokeBorder(Self.bone.opacity(0.16), lineWidth: 1))
                    .shadow(color: .black.opacity(0.35), radius: 10, y: 4)
                    .padding(.bottom, 12)
                    .transition(.scale(scale: 0.55, anchor: .bottom).combined(with: .opacity))
            }
        }
        .frame(width: PillController.size.width, height: PillController.size.height)
    }

    private var height: CGFloat { model.look == .handsFree ? 36 : 32 }
    private var padding: CGFloat {
        switch model.look {
        case .handsFree: return 6
        case .message: return 14
        default: return 13
        }
    }

    @ViewBuilder private var content: some View {
        switch model.look {
        case .listening:
            LiveBars(levels: model.levels)
        case .handsFree:
            HStack(spacing: 10) {
                PillButton(symbol: "xmark", ember: false, label: "Cancel") { model.onCancel?() }
                LiveBars(levels: model.levels)
                PillButton(symbol: "stop.fill", ember: true, label: "Stop and type") { model.onStop?() }
            }
        case .working:
            WorkingBars(still: reduceMotion)
        case .message(let text):
            Text(text)
                .font(FFFont.text(13, .medium))
                .foregroundStyle(Self.bone)
                .lineLimit(1)
                .fixedSize()
        }
    }
}

/// The live bars: each distance from the middle shows one recent level (newest in the middle).
struct LiveBars: View {
    let levels: [Float]

    var body: some View {
        HStack(alignment: .center, spacing: PillView.barGap) {
            ForEach(0..<PillView.bars, id: \.self) { i in
                let d = abs(i - PillView.bars / 2)
                let level = CGFloat(d < levels.count ? levels[d] : 0)
                let shape = PillView.shape[min(d, PillView.shape.count - 1)]
                Capsule(style: .continuous)
                    .fill(Palette.brand)
                    .frame(width: PillView.barWidth,
                           height: PillView.barMin + (PillView.barMax - PillView.barMin) * level * shape)
            }
        }
        .frame(height: PillView.barMax)
        .animation(.easeOut(duration: 0.09), value: levels)
        .accessibilityLabel("Listening")
    }
}

/// Transcribing and writing: the bars run as a slow wave (still dots with Reduce Motion).
struct WorkingBars: View {
    let still: Bool
    static let count = 7

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: still)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            HStack(spacing: PillView.barGap) {
                ForEach(0..<Self.count, id: \.self) { i in
                    let wave = still ? 0 : (sin(t * 5 - Double(i) * 0.8) + 1) / 2
                    Capsule(style: .continuous)
                        .fill(Palette.brand.opacity(0.55 + 0.45 * wave))
                        .frame(width: PillView.barWidth, height: PillView.barMin + 7 * CGFloat(wave))
                }
            }
            .frame(height: PillView.barMax)
        }
        .accessibilityLabel("Writing")
    }
}

/// A round button in the hands-free pill: cancel (bone on a dark fill) or stop (ember fill, ember-ink square).
struct PillButton: View {
    let symbol: String
    let ember: Bool
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: ember ? 9 : 10, weight: .bold))
                .foregroundStyle(ember ? Palette.accentInk : PillView.bone)
                .frame(width: 24, height: 24)
                .background(ember ? Palette.brand : PillView.bone.opacity(0.14), in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}
