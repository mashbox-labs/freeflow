import CoreText
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// Key fills in the system keyboard's own shades, so the keys sit on iOS's keyboard material in light and dark. No
/// strokes. KeyboardCanvas draws with these, in the keyboard extension and in the app's layout previews.
/// iOS 26 and later (build 18, matched to Apple's keyboard exactly): Apple draws every key the
/// same, letters, shift, delete, 123 and return alike, and leaves the space bar blank: opaque white in light; in dark
/// white at 16% over the material. Measured on an iPhone, dark: (70,72,74) keys over #222528; iPhone Air simulators
/// on iOS 27.2 and 26.5 (KeyboardMatchUITests), (68,68,68) over 32 dark and 255 over (226,227,232) light. Before
/// iOS 26: light keys for letters and space, darker keys for the rest.
public enum KeyShades {
    #if canImport(UIKit)
    public static var uniform: Bool { if #available(iOS 26, *) { return true } else { return false } }
    public static let key = Color(UIColor { $0.userInterfaceStyle == .dark ? UIColor(white: 1, alpha: uniform ? 0.162 : 0.30) : .white })
    public static let modifier = uniform ? key
        : Color(UIColor { $0.userInterfaceStyle == .dark ? UIColor(white: 1, alpha: 0.13) : UIColor(white: 0, alpha: 0.17) })
    /// A key under the finger on iOS 26 and later (before 26 a pressed key takes the other shade).
    public static let pressed = Color(UIColor { $0.userInterfaceStyle == .dark ? UIColor(white: 1, alpha: 0.30) : UIColor(white: 0, alpha: 0.17) })

    /// The fill of a key: light = letters and space.
    public static func fill(light: Bool, down: Bool) -> Color {
        if uniform { return down ? pressed : key }
        return light != down ? key : modifier
    }
    /// Not seen, only there so every point of the keyboard takes touches (2% alpha): iOS does not deliver touches to
    /// fully transparent parts of a keyboard extension, and the gaps between keys must still type (#49). The system
    /// draws the keyboard material behind us, the same material as Apple's globe/mic strip, and it changes with the app
    /// and light/dark; the floor's colour is that material's own grey, so the 2% moves a pixel by 2% of the difference:
    /// 0 levels for any material within 25 levels of it. On an iPhone, 2026-10-30, dark, same app: Apple's keyboard
    /// and strip #222528, ours #27292d with the old 2% white floor (+4.4); the floor is now #222528 in dark. Light: gray
    /// 224 (iPhone Air simulator, iOS 26.5: strip 223-225).
    public static let touchFloorUI = UIColor {
        $0.userInterfaceStyle == .dark ? UIColor(red: 34 / 255, green: 37 / 255, blue: 40 / 255, alpha: 0.02) : UIColor(white: 224 / 255, alpha: 0.02)
    }
    /// The long-press panel: opaque, so the variants read on any app.
    /// The long-press panel and its selected character, Apple's on iOS 26 and later (iOS 27.2 simulator holds, 10-30:
    /// dark panel 59-67 grey top to bottom, selected (83, 83, 86); light panel white, selected (228, 228, 230)).
    public static let callout = Color(UIColor { $0.userInterfaceStyle == .dark
        ? (uniform ? UIColor(white: 62 / 255, alpha: 1) : UIColor(red: 0.29, green: 0.30, blue: 0.31, alpha: 1)) : .white })
    public static let calloutSelected = Color(UIColor { $0.userInterfaceStyle == .dark
        ? UIColor(red: 83 / 255, green: 83 / 255, blue: 86 / 255, alpha: 1) : UIColor(red: 228 / 255, green: 228 / 255, blue: 230 / 255, alpha: 1) })
    public static let touchFloor = Color(touchFloorUI)
    #else
    public static let uniform = false
    public static let key = Color(white: 1, opacity: 0.30)
    public static let modifier = Color(white: 1, opacity: 0.13)
    public static let pressed = Color(white: 1, opacity: 0.13)
    public static func fill(light: Bool, down: Bool) -> Color { light != down ? key : modifier }
    public static let touchFloor = Color(white: 1, opacity: 0.02)
    public static let callout = Color(white: 0.3)
    public static let calloutSelected = Color(white: 0.4)
    #endif
}

/// The mic's status dot (2026-10-30): filled green = ready, hollow = not ready, no words. The same thin ring in both
/// states, so only the fill changes. Hidden from VoiceOver: the control it sits on says Ready or Not ready.
public struct StatusDot: View {
    let ready: Bool
    let ring: Color
    let size: CGFloat
    public init(ready: Bool, ring: Color, size: CGFloat = 11) { self.ready = ready; self.ring = ring; self.size = size }
    public var body: some View {
        Circle().fill(ready ? Palette.ok : Color.clear)
            .overlay(Circle().strokeBorder(ring.opacity(ready ? 0.55 : 0.75), lineWidth: 1.5))
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

/// What the keys show besides their geometry.
public struct KeyFaceState: Equatable, Sendable {
    public var shift: Bool
    public var capsLock: Bool
    public var page: KeyPage
    public var sessionLive: Bool
    public var stylePill: String
    /// The return key's label from the field (nil = the return arrow) and whether it takes the accent (ReturnKeyLabel).
    public var returnLabel: String?
    public var returnSymbol: String?
    public var returnProminent: Bool
    public init(shift: Bool = false, capsLock: Bool = false, page: KeyPage = .letters, sessionLive: Bool = false, stylePill: String,
                returnLabel: String? = nil, returnSymbol: String? = nil, returnProminent: Bool = false) {
        self.shift = shift; self.capsLock = capsLock; self.page = page; self.sessionLive = sessionLive; self.stylePill = stylePill
        self.returnLabel = returnLabel; self.returnSymbol = returnSymbol; self.returnProminent = returnProminent
    }
    public var symbols: Bool { page != .letters }
    /// The letter or symbol a key types and shows (bottom-row extras "bx:@" type "@").
    public func shown(_ id: String) -> String {
        if id.hasPrefix("bx:") { return String(id.dropFirst(3)) }
        return (shift || capsLock) && page == .letters ? id.uppercased() : id
    }
}

/// Width of a line of keyboard text in Outfit at a fixed size (FFFont.fixed), in points.
public enum KeyText {
    public static func width(_ text: String, size: CGFloat, weight: Font.Weight) -> Double {
        let font = FFFont.fixedCT(size, weight)
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font]))
        return CTLineGetTypographicBounds(line, nil, nil, nil)
    }
}

/// The style key's label: one line of Outfit Bold 16 pt at the large text size (no Dynamic Type scaling, like the
/// system keyboard), 6 pt in from each side of the drawn key. FreeFlowKit KeyboardFacesTests checks every
/// DictationStyle pill needs no less than 0.8 of that size in every layout, hand and screen width.
public enum StyleKeyText {
    public static let size: CGFloat = 16
    public static let weight: Font.Weight = .bold
    public static let padding: CGFloat = 6
    /// The drawing's floor so a label never wraps or clips; the test keeps every pill at 0.8 or more.
    public static let minimumScale: CGFloat = 0.5

    /// Scale the label needs on a drawn key this wide (1 = full size).
    public static func scale(_ pill: String, keyWidth: Double) -> Double {
        min(1, (keyWidth - 2 * padding) / KeyText.width(pill, size: size, weight: weight))
    }
}

/// The keyboard's top bar in its opening, didn't-open and message states (KeyboardViewController topBar): style pill,
/// cleanup chip, spacer, mic, spacer, status dot, hide key, on one line. The bar is built from these numbers;
/// FreeFlowKit KeyboardFacesTests checks the style pill's text fits at every width, with the cleanup chip where it shows.
public enum KeyboardTopBar {
    /// The style pill's text never goes below this share of its size.
    public static let readable = 0.8
    /// Each side: the bar's own padding (8) and its stack's (4).
    public static let barPadding: CGFloat = 8
    public static let stackPadding: CGFloat = 4
    /// Between the seven items. Was 10; 6 gives the style pill's text its full size at 375 pt.
    public static let spacing: CGFloat = 6
    public static let mic: CGFloat = 46
    public static let dot: CGFloat = 28
    public static let hide: CGFloat = 54
    public static let styleSize: CGFloat = 16
    public static let stylePadding: CGFloat = 14
    public static let cleanupSize: CGFloat = 14
    public static let cleanupPadding: CGFloat = 11

    /// The cleanup chip at full size (it does not shrink).
    public static func cleanupWidth(_ title: String) -> Double {
        KeyText.width(title, size: cleanupSize, weight: .semibold) + 2 * Double(cleanupPadding)
    }

    /// Room for the style pill's text at keyboard width `width`: the width less the paddings, the gaps, the fixed
    /// items and the cleanup chip when it shows (the spacers can shrink to nothing).
    public static func styleTextRoom(width: Double, cleanup: String?) -> Double {
        width - 2 * Double(barPadding + stackPadding) - Double(cleanup == nil ? 5 : 6) * Double(spacing) - Double(mic + dot + hide)
            - (cleanup.map(cleanupWidth) ?? 0) - 2 * Double(stylePadding)
    }

    /// Build 12: no cleanup chip (no rule-based cleanup, 2026-10-30), so the bar never shows one.
    public static func showsCleanup(width: Double) -> Bool { false }

    /// Scale the style pill's text needs in the bar as drawn at this width with this cleanup level (1 = full size).
    public static func styleScale(_ pill: String, width: Double, cleanup: String) -> Double {
        let room = styleTextRoom(width: width, cleanup: showsCleanup(width: width) ? cleanup : nil)
        return min(1, room / KeyText.width(pill, size: styleSize, weight: .bold))
    }
}

/// One key as the Free Flow keyboard draws it. Drawn only inside KeyboardCanvas.
public struct KeyFace: View {
    let key: KeySlot
    let state: KeyFaceState
    let down: Bool

    public init(_ key: KeySlot, state: KeyFaceState, down: Bool = false) { self.key = key; self.state = state; self.down = down }

    public var body: some View {
        let k = key
        switch k.id {
        case "mic":
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Palette.brand)
                // 2026-10-30: no words on the bar. The mic in the middle and one status dot: filled green = ready,
                // hollow = not ready. VoiceOver keeps the words (the keyboard labels this key).
                .overlay(Image(systemName: "mic.fill").font(.system(size: 24, weight: .semibold)))
                .overlay(alignment: .trailing) { StatusDot(ready: state.sessionLive, ring: Palette.accentInk).padding(.trailing, 18) }
                .foregroundStyle(Palette.accentInk)
                .opacity(down ? 0.85 : 1)
        case "style":
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(KeyShades.fill(light: false, down: down))
                .overlay(Text(state.stylePill).font(FFFont.fixed(StyleKeyText.size, StyleKeyText.weight))
                    .minimumScaleFactor(StyleKeyText.minimumScale).lineLimit(1).padding(.horizontal, StyleKeyText.padding))
        case "hide":
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(KeyShades.fill(light: false, down: down))
                .overlay(Image(systemName: "keyboard.chevron.compact.down").font(.system(size: 21, weight: .medium)))
        case "return" where k.visible2 != nil:
            // One key, one shape: a reverse L in the bottom-right corner, labelled on its bottom-row foot (iPad v1 kept
            // the L with the tall labelled part on the left; ReturnShape draws both).
            let box = k.drawn, tall = k.visible.offsetBy(dx: -box.minX, dy: -box.minY)
            let short = k.visible2!.offsetBy(dx: -box.minX, dy: -box.minY)
            let label = tall.minX <= short.minX ? tall : short
            ZStack(alignment: .topLeading) {
                ReturnShape(tall: tall, short: short)
                    .fill(KeyShades.fill(light: false, down: down))
                VStack(spacing: 1) {
                    Image(systemName: "return").font(.system(size: 20, weight: .semibold))
                    Text("return").font(FFFont.fixed(15, .bold)).lineLimit(1).minimumScaleFactor(0.7)
                }
                .frame(width: label.width, height: label.height)
                .offset(x: label.minX, y: label.minY)
            }
        case "blank":
            Color.clear   // the number pad's empty corner, as Apple's
        case "delete" where state.page.isPad, "." where state.page.isPad:
            // Apple's pad: delete and the decimal point sit on the keyboard with no key behind them
            caption.opacity(down ? 0.5 : 1)
        default:
            let light = k.kind == .letter || k.id == "space"
            let prominent = k.id == "return" && state.returnProminent
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(prominent ? Palette.brand : KeyShades.fill(light: light, down: down))
                .overlay(caption.foregroundStyle(prominent ? AnyShapeStyle(Palette.accentInk) : AnyShapeStyle(.primary)))
                .opacity(prominent && down ? 0.85 : 1)
        }
    }

    /// Key labels in Outfit (MASHBOX visual language), 2026-10-30, slightly bolder than Regular but not Bold:
    /// Medium for letters, digits and symbols, SemiBold for the word keys.
    static let glyph = FFFont.fixed(24, .medium)
    static let word = FFFont.fixed(17, .semibold)

    @ViewBuilder private var caption: some View {
        switch key.id {
        case "shift":
            Image(systemName: state.capsLock ? "capslock.fill" : (state.shift ? "shift.fill" : "shift")).font(.system(size: 20, weight: .medium))
        case "delete": Image(systemName: "delete.left").font(.system(size: 20, weight: .medium))
        case "globe": Image(systemName: "globe").font(.system(size: 20))
        case "abc123": Text(state.page == .letters ? "123" : "ABC").font(Self.word)
        case "more":
            Text(state.page == .symbols ? "123" : "#+=").font(Self.word)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .overlay(alignment: .topTrailing) {
                    // Build 23: a small smiley says a hold on this key opens iOS's keyboard list (Emoji).
                    Image(systemName: "face.smiling").font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.secondary).padding(.top, 4).padding(.trailing, 5)
                        .accessibilityHidden(true)
                }
        case "padmore": Text(state.page == .padSymbols ? "123" : "+*#").font(Self.word)
        case "space":
            if !KeyShades.uniform { Text("space").font(Self.word) }   // iOS 26 and later: blank, as Apple's
        case "return" where key.visible.height > key.visible.width:
            // L3: one tall key in the corner column
            VStack(spacing: 2) {
                Image(systemName: "return").font(.system(size: 20, weight: .semibold))
                Text("return").font(FFFont.fixed(13, .bold)).lineLimit(1).minimumScaleFactor(0.6)
            }
            .padding(.horizontal, 2)
        case "return":
            // Apple's: the return arrow, or the field's word (go, search, send...)
            if let symbol = state.returnSymbol {
                Image(systemName: symbol).font(.system(size: 20, weight: .semibold))
            } else if let label = state.returnLabel {
                Text(label).font(Self.word).lineLimit(1).minimumScaleFactor(0.6).padding(.horizontal, 4)
            } else {
                Image(systemName: "return").font(.system(size: 20, weight: .medium))
            }
        default:
            if state.page.isPad, Int(key.id) != nil {
                VStack(spacing: -2) {
                    Text(key.id).font(FFFont.fixed(26, .medium))
                    let sub = state.page == .pad ? PadCaption.letters(key.id) : ""
                    if !sub.isEmpty { Text(sub).font(FFFont.fixed(10, .semibold)).tracking(1.5) }
                }
            } else if key.id.hasPrefix("bx:") && key.id.count > 4 {
                Text(state.shown(key.id)).font(Self.word)
            } else {
                Text(state.shown(key.id)).font(Self.glyph)
            }
        }
    }
}

/// Return's outline, one shape. v1 (tall part left of the short part): the tall part's top edge, a step down at its
/// right edge to the short part, the short part's right and bottom edges. v2 (`tall` is the arm at the right end of
/// the foot): the foot's top edge to the arm, up the arm, down the screen-side edge, along the bottom. Rounded like
/// the other keys (8 pt), the inner corner a little less. Fill only, no stroke.
public struct ReturnShape: Shape {
    let tall: CGRect
    let short: CGRect

    public init(tall: CGRect, short: CGRect) { self.tall = tall; self.short = short }

    public func path(in rect: CGRect) -> Path {
        let bottom = max(tall.maxY, short.maxY)
        let pts: [CGPoint]
        let radii: [CGFloat]
        if tall.minX <= short.minX {
            pts = [CGPoint(x: tall.minX, y: tall.minY), CGPoint(x: tall.maxX, y: tall.minY), CGPoint(x: tall.maxX, y: short.minY),
                   CGPoint(x: short.maxX, y: short.minY), CGPoint(x: short.maxX, y: bottom), CGPoint(x: tall.minX, y: bottom)]
            radii = [8, 8, 6, 8, 8, 8]
        } else {
            pts = [CGPoint(x: short.minX, y: short.minY), CGPoint(x: tall.minX, y: short.minY), CGPoint(x: tall.minX, y: tall.minY),
                   CGPoint(x: tall.maxX, y: tall.minY), CGPoint(x: tall.maxX, y: bottom), CGPoint(x: short.minX, y: bottom)]
            radii = [8, 6, 8, 8, 8, 8]
        }
        var p = Path()
        let n = pts.count
        p.move(to: CGPoint(x: (pts[n - 1].x + pts[0].x) / 2, y: (pts[n - 1].y + pts[0].y) / 2))
        for i in 0..<n {
            let r = min(radii[i], abs(pts[(i + 1) % n].x - pts[i].x) / 2 + abs(pts[(i + 1) % n].y - pts[i].y) / 2)
            p.addArc(tangent1End: pts[i], tangent2End: pts[(i + 1) % n], radius: r)
        }
        p.closeSubpath()
        return p
    }
}

public extension Array where Element == KeySlot {
    /// Drawing order: return first, so its face sits under the letters next to its L (m stays the top element where
    /// they meet, for VoiceOver and UI-test hit tests).
    var returnFirst: [KeySlot] { filter { $0.id == "return" } + filter { $0.id != "return" } }
}

/// What the keys sit on.
public enum KeyboardBackdrop: Sendable {
    /// The keyboard extension: iOS draws its keyboard material behind the extension, and the extension's own view
    /// carries KeyShades.touchFloor (KeyboardViewController). Nothing more is drawn here.
    case system
    /// The app's layout previews: Apple's in-app copy of that material (UIInputView, .keyboard style: "mimics the
    /// keyboard background") under the same touch floor.
    case inApp
}

/// The Free Flow keyboard's drawing, the one view for the keyboard extension and every Settings > Keyboard > Layout
/// preview: the backdrop and every key face (the Dictate bar with its status dot, the style key, the hide key, letters,
/// return), at the keyboard's real size. The extension adds only its VoiceOver elements and touch surface on top, so a
/// restyle here changes the keyboard and the previews together (UI test testKPreviewMatchesKeyboard compares them).
public struct KeyboardCanvas: View {
    let keys: [KeySlot]
    let state: KeyFaceState
    let pressed: Set<String>
    let backdrop: KeyboardBackdrop

    public init(keys: [KeySlot], state: KeyFaceState, pressed: Set<String> = [], backdrop: KeyboardBackdrop) {
        self.keys = keys; self.state = state; self.pressed = pressed; self.backdrop = backdrop
    }

    public var body: some View {
        ZStack(alignment: .topLeading) {
            if backdrop == .inApp {
                KeyboardMaterial()
                KeyShades.touchFloor
            }
            // Return first: its face is drawn under the letters next to its L.
            ForEach(keys.returnFirst, id: \.id) { k in
                KeyFace(k, state: state, down: pressed.contains(k.id))
                    .frame(width: k.drawn.width, height: k.drawn.height)
                    .position(x: k.drawn.midX, y: k.drawn.midY)
            }
        }
        .foregroundStyle(.primary)
        .dynamicTypeSize(...DynamicTypeSize.large)
    }
}

#if canImport(UIKit)
/// Apple's keyboard material in the app: a UIInputView with the .keyboard style, which UIKit documents as mimicking
/// the keyboard background. Touches pass through (the preview's card takes them).
struct KeyboardMaterial: UIViewRepresentable {
    func makeUIView(context: Context) -> UIInputView {
        let v = UIInputView(frame: CGRect(x: 0, y: 0, width: 320, height: 216), inputViewStyle: .keyboard)
        v.isUserInteractionEnabled = false
        return v
    }

    func updateUIView(_ v: UIInputView, context: Context) {}
}
#else
/// macOS (FreeFlowKit's tests only): no keyboard material.
struct KeyboardMaterial: View {
    var body: some View { Color.clear }
}
#endif

/// The keyboard as it shows on screen for a layout, at its real size: the same geometry (KeyboardLayouts) and the same
/// drawing (KeyboardCanvas) as the keyboard extension. Settings > Keyboard > Layout shows it.
public struct KeyboardPreview: View {
    let kind: KeyLayoutKind
    let width: Double
    let isPad: Bool
    let scale: Double
    let hand: KeyHand
    let globe: Bool
    let state: KeyFaceState

    public init(kind: KeyLayoutKind, width: Double, isPad: Bool, scale: Double, hand: KeyHand, globe: Bool, state: KeyFaceState) {
        self.kind = kind; self.width = width; self.isPad = isPad; self.scale = scale; self.hand = hand; self.globe = globe; self.state = state
    }

    public var body: some View {
        let h = KeyboardLayouts.height(width: width, isPad: isPad)
        let keys = KeyboardLayouts.keys(kind, width: width, height: h, isPad: isPad, scale: scale, globe: globe, hand: hand)
        KeyboardCanvas(keys: keys, state: state, backdrop: .inApp)
            .frame(width: width, height: h)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(kind.title) keyboard preview")
    }
}

/// The long-press panel over a key (Apple's accent and symbol variants, KeyCallouts): opaque, above the key, the
/// variant under the finger in the brand orange. Positions come from CalloutGeometry, which the touch code uses too.
public struct KeyCalloutView: View {
    let options: [String]
    let selected: Int
    let panel: CGRect
    let cells: [CGRect]

    public init(options: [String], selected: Int, panel: CGRect, cells: [CGRect]) {
        self.options = options; self.selected = selected; self.panel = panel; self.cells = cells
    }

    public var body: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 12, style: .continuous).fill(KeyShades.callout)
                .shadow(color: .black.opacity(0.28), radius: 6, y: 2)
                .frame(width: panel.width, height: panel.height)
                .position(x: panel.midX, y: panel.midY)
            ForEach(Array(zip(options.indices, cells)), id: \.0) { i, c in
                ZStack {
                    if i == selected { RoundedRectangle(cornerRadius: 8, style: .continuous).fill(KeyShades.calloutSelected) }
                    Text(options[i]).font(KeyFace.glyph).foregroundStyle(.primary)
                }
                .frame(width: c.width, height: c.height)
                .position(x: c.midX, y: c.midY)
            }
        }
        .allowsHitTesting(false)
    }
}
