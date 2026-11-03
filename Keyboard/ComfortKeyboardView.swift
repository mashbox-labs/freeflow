import FreeFlowKit
import SwiftUI
import UIKit

/// Every layout (Settings > Keyboard > Layout): dictation first. Geometry comes from FreeFlowKit KeyboardLayouts and
/// the whole drawing from FreeFlowKit KeyboardCanvas, the same view the app's layout previews draw with. This view adds
/// only what a keyboard needs on top: one VoiceOver element per key, and a UIKit surface that takes the touches so
/// every point of the keyboard belongs to a key and fast two-thumb typing keeps every key (a new touch commits the one
/// still down, like the system keyboard).
struct ComfortKeyboard: View {
    @ObservedObject var model: KeyboardModel
    let showsGlobe: Bool
    @State private var pressed: Set<String> = []
    /// The long-press panel while a finger holds a key with variants (build 18).
    @State private var callout: CalloutState?
    struct CalloutState { var key: KeySlot; var panel: CalloutPanel; var selected: Int }
    @Environment(\.displayScale) private var scale
    /// A layout picked in Settings while the keyboard is up applies at once (the App Group value is read twice a second).
    private let layoutCheck = Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()

    private var face: KeyFaceState {
        KeyFaceState(shift: model.shift, capsLock: model.capsLock, page: model.page, sessionLive: model.sessionLive,
                     stylePill: model.style.pill, returnLabel: ReturnKeyLabel.text(model.returnRaw),
                     returnSymbol: KeyShades.uniform ? ReturnKeyLabel.symbol(model.returnRaw) : nil, returnProminent: ReturnKeyLabel.prominent(model.returnRaw))
    }

    var body: some View {
        GeometryReader { geo in
            let keys = ComfortMetrics.keys(kind: model.layout, size: geo.size, scale: scale, globe: showsGlobe, page: model.page,
                                           field: model.field, hand: model.hand, styleKey: model.styleKey)
            ZStack(alignment: .topLeading) {
                // The drawing: FreeFlowKit KeyboardCanvas, shared with the app's layout previews. Taps between keys
                // reach the touch surface because of the near-invisible floor on the controller's view
                // (KeyShades.touchFloor); on a fully transparent keyboard iOS dropped them.
                KeyboardCanvas(keys: keys, state: face, pressed: pressed, backdrop: .system)
                    .accessibilityHidden(true)
                if let c = callout {
                    let g = CalloutGeometry.layout(key: c.key.visible, panel: c.panel, width: Double(geo.size.width))
                    KeyCalloutView(options: c.panel.options, selected: c.selected, panel: g.panel, cells: g.cells)
                        .accessibilityHidden(true)
                }
                // VoiceOver and UI tests: one SwiftUI element per key, at the drawn key, over the drawing and under the
                // touch surface. (UIAccessibilityElements inside the UIKit surface got no screen frame in the keyboard
                // extension, which does not know where its window sits on screen; SwiftUI's elements do.)
                // Return first, as drawn, so the letters next to its L (m) stay the top element where they are
                // (VoiceOver and UI-test hit tests).
                ZStack(alignment: .topLeading) {
                    ForEach(keys.returnFirst, id: \.id) { k in
                        Color.clear
                            .frame(width: k.drawn.width, height: k.drawn.height)
                            .contentShape(Rectangle())
                            .accessibilityElement()
                            .accessibilityLabel(label(k))
                            .accessibilityIdentifier(identifier(k))
                            .accessibilityAddTraits(k.kind == .action ? .isButton : .isKeyboardKey)
                            .accessibilityAction { activate(k.id) }
                            .position(x: k.drawn.midX, y: k.drawn.midY)
                    }
                }
                // The keyboard's own frame for UI tests (a container: VoiceOver goes straight to the keys).
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("kb.keyboard")
                KeySurface(keys: keys,
                           down: { id in pressed.insert(id); model.feel.press(kind(id)); if id == "delete" { model.deleteKey() } },
                           up: { id in pressed.remove(id) },
                           commit: perform,
                           repeatKey: { id in if id == "delete" { model.deleteRepeat() } },
                           canHold: { id in KeyCallouts.panel(id, page: model.page, upper: false) != nil },
                           holdBegan: { id in
                               guard let k = keys.first(where: { $0.id == id }) else { return }
                               if let panel = KeyCallouts.panel(id, page: model.page, upper: model.shift || model.capsLock) {
                                   callout = CalloutState(key: k, panel: panel, selected: panel.base)
                               }
                           },
                           holdMoved: { p in
                               guard var c = callout else { return }
                               let g = CalloutGeometry.layout(key: c.key.visible, panel: c.panel, width: Double(geo.size.width))
                               let i = CalloutGeometry.selected(at: p, cells: g.cells)
                               if i != c.selected { c.selected = i; callout = c }
                           },
                           holdEnded: { commit in
                               if commit, let c = callout { model.typeLetter(c.panel.options[c.selected]) }
                               callout = nil
                           },
                           inputController: model.inputController)
                    .accessibilityHidden(true)
            }
        }
        .onReceive(layoutCheck) { _ in
            let layout = KeyLayoutKind.current, hand = KeyHand.current
            if model.layout != layout { model.layout = layout }
            if model.hand != hand { model.hand = hand }
            let styleKey = SharedSession.styleKeyShown
            if model.styleKey != styleKey { model.styleKey = styleKey }
        }
    }

    // MARK: actions

    private func shown(_ id: String) -> String { face.shown(id) }

    private func kind(_ id: String) -> KeyTick.Kind {
        switch id {
        case "space": .space
        case "return": .enter
        case "delete": .delete
        case "mic": .mic
        case "shift", "abc123", "more", "padmore", "blank", "globe", "style", "hide": .modifier
        default: .letter
        }
    }

    /// VoiceOver double tap: the same action as a touch (delete removes one character).
    private func activate(_ id: String) {
        if id == "delete" { model.feel.press(.delete); model.deleteKey() } else { perform(id) }
    }

    private func perform(_ id: String) {
        switch id {
        case "mic": model.tapMic()
        case "style": model.cycleStyle()
        case "hide": model.dismiss?()
        case "shift": if model.page == .letters { model.tapShift() }
        case "delete": break // fired on touch down and repeats while held
        case "abc123": model.setPage(model.page == .letters ? .numbers : .letters)
        case "more": model.setPage(model.page == .numbers ? .symbols : .numbers)
        case "padmore": model.setPage(model.page == .pad ? .padSymbols : .pad)
        case "blank": break
        case "globe": model.nextKeyboard?()
        case "space": model.typeSpace()
        case "return": model.typeReturn()
        default: model.typeLetter(shown(id))
        }
    }

    private func label(_ k: KeySlot) -> String {
        switch k.id {
        case "mic": model.sessionLive ? "Dictate, ready" : "Dictate, not ready"
        case "style": "Style, \(model.style.pill)"
        case "hide": "Hide keyboard"
        case "abc123": model.page == .letters ? "Numbers" : "Letters"
        case "more": model.page == .symbols ? "Numbers" : "More symbols"
        case "padmore": model.page == .padSymbols ? "Numbers" : "Plus, star and hash"
        case "blank": ""
        case "shift": model.capsLock ? "caps lock" : "shift"
        case "return": ReturnKeyLabel.text(model.returnRaw) ?? "return"
        case "delete", "space", "globe": k.id
        default: shown(k.id)
        }
    }

    private func identifier(_ k: KeySlot) -> String {
        switch k.id {
        case "mic": "kb.mic"
        case "style": "kb.style"
        case "hide": "kb.hide"
        case "abc123": "key.123"
        default: "key.\(k.id)"
        }
    }
}

enum ComfortMetrics {
    static var isPad: Bool { UIDevice.current.userInterfaceIdiom == .pad }

    /// The keys of a layout at this size (FreeFlowKit KeyboardLayouts: the same code draws the Settings preview).
    static func keys(kind: KeyLayoutKind, size: CGSize, scale: CGFloat, globe: Bool, page: KeyPage = .letters,
                     field: KeyField = .text, hand: KeyHand, styleKey: Bool = true) -> [KeySlot] {
        KeyboardLayouts.keys(kind, width: size.width, height: size.height, isPad: isPad, scale: Double(scale),
                             globe: globe, hand: hand, page: page, field: field, styleKey: styleKey)
    }

    /// Keyboard height: the action row stays 54 pt tall over the four key rows (iPhone: Apple's measured rows; iPad:
    /// Apple's iPad row pitch). The same in every layout, so switching layouts never moves the keyboard's top.
    static func height(width: CGFloat) -> CGFloat {
        CGFloat(KeyboardLayouts.height(width: Double(width), isPad: isPad))
    }
}

/// Touches for the Comfort keys (VoiceOver uses the SwiftUI key faces).
struct KeySurface: UIViewRepresentable {
    let keys: [KeySlot]
    let down: (String) -> Void
    let up: (String) -> Void
    let commit: (String) -> Void
    let repeatKey: (String) -> Void
    /// Long press (build 18): keys with variants open a panel after 0.42 s; sliding picks, lifting types the pick.
    let canHold: (String) -> Bool
    let holdBegan: (String) -> Void
    let holdMoved: (CGPoint) -> Void
    let holdEnded: (Bool) -> Void
    /// Build 23: the globe's touches go to this controller's handleInputModeList(from:with:).
    weak var inputController: UIInputViewController?

    func makeUIView(context: Context) -> KeySurfaceView {
        let v = KeySurfaceView()
        v.isMultipleTouchEnabled = true
        v.backgroundColor = .clear
        v.isAccessibilityElement = false
        v.accessibilityElementsHidden = true
        return v
    }

    func updateUIView(_ v: KeySurfaceView, context: Context) { v.surface = self }
}

final class KeySurfaceView: UIView {
    var surface: KeySurface? { didSet { placeGlobe() } }

    /// Build 23: the globe key is a UIKit control wired to UIInputViewController.handleInputModeList(from:with:)
    /// for all touch events, as Apple's custom-keyboard guide sets up the next-keyboard key: a tap goes to the next
    /// keyboard, a long press opens iOS's keyboard list (Emoji is one tap there). It sits over the drawn globe only where
    /// the layout draws one (needsInputModeSwitchKey); every other key keeps this view's touch path below.
    let globe = GlobeControl()
    override init(frame: CGRect) {
        super.init(frame: frame)
        globe.isHidden = true
        globe.isAccessibilityElement = false
        globe.addTarget(self, action: #selector(globeDown), for: .touchDown)
        globe.addTarget(self, action: #selector(globeUp), for: [.touchUpInside, .touchUpOutside, .touchCancel])
        addSubview(globe)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private func placeGlobe() {
        guard let s = surface, let controller = s.inputController, let key = s.keys.first(where: { $0.id == "globe" }) else {
            globe.isHidden = true
            return
        }
        globe.frame = key.hit
        globe.isHidden = false
        globe.wire(to: controller)
    }

    @objc private func globeDown() { surface?.down("globe") }
    @objc private func globeUp() { surface?.up("globe") }

    /// Finger touches always come with an event and stay here. Accessibility hit tests (VoiceOver touch
    /// exploration, UI tests) come without one and go through to the SwiftUI key elements underneath.
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        event == nil ? nil : super.hitTest(point, with: event)
    }
    private struct Active { let touch: UITouch; var key: String; var spent: Bool; var holding = false; var listing = false; var listStarted = false }
    private var active: [Active] = []
    private var repeatTimer: Timer?
    private var holdTimer: Timer?
    static let holdDelay: TimeInterval = 0.42
    /// Build 23: a hold on the page-flip key (#+= on the numbers page, 123 on the symbols page) hands its
    /// touch to UIInputViewController.handleInputModeList(from:with:), which opens iOS's keyboard list (Emoji one tap
    /// away); a tap still flips the page. Every layout has this key; the globe, where drawn, does the same.
    static let listKey = "more"
    static let listDelay: TimeInterval = 0.5
    private var listTimer: Timer?
    /// A tap's lift goes to iOS against this view, far from the finger, so iOS reads a lift outside (no keyboard
    /// change, no list) and the tap stays our page flip. The touch-down, a hold and its slide go against this view.
    private let listAnchor: UIView = {
        let v = UIView(); v.isUserInteractionEnabled = false; v.backgroundColor = .clear; return v
    }()
    private static let away = CGRect(x: -20_000, y: -20_000, width: 1, height: 1)

    /// iOS starts its list from the touch's first event (handed over later it opened nothing on the iPad Pro 13
    /// simulator), so the touch-down goes to it at once; the rest of the touch goes to it only once held listDelay,
    /// and a shorter touch stays ours (the page flip).
    private func startList(_ t: UITouch, _ event: UIEvent?, _ s: KeySurface) {
        guard let event, let controller = s.inputController,
              let i = active.firstIndex(where: { $0.touch === t }) else { return }
        if listAnchor.superview !== self { insertSubview(listAnchor, at: 0) }
        active[i].listStarted = true
        controller.handleInputModeList(from: self, with: event)
        listTimer?.invalidate()
        listTimer = Timer.scheduledTimer(withTimeInterval: Self.listDelay, repeats: false) { [weak self] _ in
            guard let self, let i = self.active.firstIndex(where: { $0.touch === t }),
                  !self.active[i].spent, self.active[i].key == Self.listKey else { return }
            self.active[i].spent = true        // held: no page flip on lift; the rest of the touch is iOS's
            self.active[i].listing = true
        }
    }

    /// The rest of a held page-flip key's touch goes to iOS's list (slide to pick, lift to choose).
    private func forwardList(_ touches: Set<UITouch>, _ event: UIEvent?, ending: Bool = false) -> Bool {
        guard let event, let controller = surface?.inputController else { return false }
        if active.contains(where: { $0.listing && touches.contains($0.touch) }) {
            controller.handleInputModeList(from: self, with: event)
            return true
        }
        // A tap: iOS saw the touch-down, so it must see the lift too, outside its view, or it opens the list anyway.
        if ending, active.contains(where: { $0.listStarted && touches.contains($0.touch) }) {
            listAnchor.frame = Self.away
            controller.handleInputModeList(from: listAnchor, with: event)
            return true
        }
        return false
    }

    private func key(at touch: UITouch) -> String? {
        guard let s = surface else { return nil }
        return KeyGeometry.key(at: touch.location(in: self), in: s.keys)?.id
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let s = surface else { return }
        // Rollover: a new finger commits the keys still held, in order, so fast two-thumb typing drops nothing.
        for i in active.indices where !active[i].spent { finish(i, s) }
        for t in touches.sorted(by: { $0.timestamp < $1.timestamp }) {
            guard let id = key(at: t) else { continue }
            active.append(Active(touch: t, key: id, spent: id == "delete"))
            s.down(id)
            if id == "delete" { startRepeat(id, s) } else if s.canHold(id) { startHold(t, id, s) }
            else if id == Self.listKey { startList(t, event, s) }
        }
    }

    private func startHold(_ t: UITouch, _ id: String, _ s: KeySurface) {
        holdTimer?.invalidate()
        holdTimer = Timer.scheduledTimer(withTimeInterval: Self.holdDelay, repeats: false) { [weak self] _ in
            guard let self, let i = self.active.firstIndex(where: { $0.touch === t }),
                  !self.active[i].spent, self.active[i].key == id else { return }
            self.active[i].holding = true
            s.holdBegan(id)
            s.holdMoved(t.location(in: self))
        }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let s = surface else { return }
        _ = forwardList(touches, event)
        for i in active.indices where touches.contains(active[i].touch) && !active[i].spent && active[i].key != "delete" {
            if active[i].holding { s.holdMoved(active[i].touch.location(in: self)); continue }
            if let id = key(at: active[i].touch), id != active[i].key {
                s.up(active[i].key); active[i].key = id; s.down(id)
                if s.canHold(id) { startHold(active[i].touch, id, s) } else { holdTimer?.invalidate() }
            }
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let s = surface else { return }
        _ = forwardList(touches, event, ending: true)
        for i in active.indices where touches.contains(active[i].touch) && !active[i].spent { finish(i, s) }
        release(touches, s)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let s = surface else { return }
        _ = forwardList(touches, event, ending: true)
        for i in active.indices where touches.contains(active[i].touch) && active[i].holding && !active[i].spent {
            active[i].spent = true
            s.holdEnded(false)
        }
        release(touches, s)
    }

    private func finish(_ i: Int, _ s: KeySurface) {
        active[i].spent = true
        if active[i].holding { s.holdEnded(true); return }   // the variant picked in the panel types
        // The key under the finger types: plain tiles that fill the gaps, no prediction.
        s.commit(active[i].key)
    }

    private func release(_ touches: Set<UITouch>, _ s: KeySurface) {
        for a in active where touches.contains(a.touch) {
            s.up(a.key)
            if a.key == "delete" { repeatTimer?.invalidate(); repeatTimer = nil }
        }
        if active.allSatisfy({ touches.contains($0.touch) }) {
            holdTimer?.invalidate(); holdTimer = nil
            listTimer?.invalidate(); listTimer = nil
        }
        active.removeAll { touches.contains($0.touch) }
    }

    private func startRepeat(_ id: String, _ s: KeySurface) {
        repeatTimer?.invalidate()
        repeatTimer = Timer.scheduledTimer(withTimeInterval: 0.45, repeats: false) { [weak self] _ in
            self?.repeatTimer = Timer.scheduledTimer(withTimeInterval: 0.09, repeats: true) { _ in s.repeatKey(id) }
        }
    }
}

/// The globe key's touches (build 23): every touch event goes to UIInputViewController.handleInputModeList(from:with:).
final class GlobeControl: UIControl {
    private(set) weak var wiredTo: UIInputViewController?
    static let inputModeList = #selector(UIInputViewController.handleInputModeList(from:with:))

    func wire(to controller: UIInputViewController) {
        guard wiredTo !== controller else { return }
        if let old = wiredTo { removeTarget(old, action: Self.inputModeList, for: .allTouchEvents) }
        addTarget(controller, action: Self.inputModeList, for: .allTouchEvents)
        wiredTo = controller
    }
}

/// Listening and Writing, every layout: the finish key is the Comfort Dictate key itself (same frame, colour and
/// corner) with a check mark for its label. Cancel, the title and the waveform as before.
struct ListeningKeyboard: View {
    @ObservedObject var model: KeyboardModel
    let showsGlobe: Bool
    @Environment(\.displayScale) private var scale

    var body: some View {
        GeometryReader { geo in
            let keys = ComfortMetrics.keys(kind: model.layout, size: geo.size, scale: scale, globe: showsGlobe, hand: model.hand,
                                           styleKey: model.styleKey)
            let dictate = keys.first { $0.id == "mic" }?.visible ?? .zero
            // Build 26: .starting is the moment between the keyboard's ask after a trip and the app recording (the
            // pre-roll keeps what is said in it); "Listening, speak now" only once the app really records.
            let starting = model.mode == .starting
            let busy = model.mode == .writing || starting
            let title = starting ? ColdStart.Words.keyboardStarting
                : (busy ? model.stage : (model.afterTrip ? ColdStart.Words.keyboardLive : "Listening"))
            ZStack(alignment: .topLeading) {
                VStack(spacing: 8) {
                    ListeningPanel(levels: model.levels, title: title, subtitle: model.inputName, busy: busy,
                                   idPrefix: "kb.", finishInline: false, cancelTrailing: model.hand == .left,
                                   onCancel: { model.cancel() }, onFinish: { model.finish() })
                        .padding(.horizontal, 3).padding(.top, 3)
                    Spacer(minLength: 0)
                    // Hide key on the thumb's side: dictation keeps running and the text lands when the keyboard is back.
                    HStack(spacing: 8) {
                        if model.hand == .left { HideKey(model: model) }
                        Text("Swipe down with two fingers to finish").font(FFFont.text(13)).foregroundStyle(Palette.faint)
                            .frame(maxWidth: .infinity, alignment: model.hand == .left ? .trailing : .leading)
                        if model.hand == .right { HideKey(model: model) }
                    }
                    .padding(.horizontal, 6).padding(.bottom, 6)
                }
                Button { model.finish() } label: {
                    RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Palette.brand)
                        .overlay(Image(systemName: "checkmark").font(.system(size: 24, weight: .bold)).foregroundStyle(Palette.accentInk))
                        .frame(width: dictate.width, height: dictate.height)
                        .contentShape(Rectangle())
                }
                .buttonStyle(ClickStyle(kind: .mic, feel: model.feel))
                .disabled(busy).opacity(busy ? 0.5 : 1)
                .accessibilityIdentifier("kb.finishButton").accessibilityLabel("Finish")
                .position(x: dictate.midX, y: dictate.midY)
            }
        }
    }
}
