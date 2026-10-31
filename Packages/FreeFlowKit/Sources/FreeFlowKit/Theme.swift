import CoreText
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// MASHBOX Visual Language v1 (2026-10-29). Values are copied from
/// MashboxTheme.swift, which copies the live mashbox.gg homepage. The names here are Free Flow's older ones
/// (each comment gives the MBX token) so the app, the keyboard and the widgets all switch together.
/// The stroke rule: a view gets a full thin rounded stroke (`ffStroke`) or none. Never one edge.
public enum Palette {
    public static let brand = Color(hex: 0xFF5A1F)                       // MBX.ember
    public static let bg = dynamic(light: 0xF6F3ED, dark: 0x0B0A09)      // MBX.paper
    public static let surface = dynamic(light: 0xECE7DD, dark: 0x171411) // MBX.paper2: cards
    public static let panel = dynamic(light: 0xE2DCCF, dark: 0x211D19)   // MBX.paper3: tags, current item
    public static let fg = dynamic(light: 0x0B0A09, dark: 0xECE6DA)      // MBX.ink
    public static let muted = dynamic(light: 0x4D4740, dark: 0xB3AB9E)   // MBX.ink2
    public static let faint = dynamic(light: 0x776F65, dark: 0x857D71)   // MBX.ink3
    public static let line = dynamic(light: 0xE0DACD, dark: 0x24201C)    // MBX.rule
    public static let lineStrong = dynamic(light: 0xCDC5B6, dark: 0x37312B) // MBX.rule2
    public static let accentText = dynamic(light: 0xB8400F, dark: 0xFF8A5C) // MBX.emberText
    public static let accentSoft = Color(hex: 0xFF5A1F).opacity(0.14)
    public static let accentInk = Color(hex: 0x1A0B04)                   // MBX.emberInk
    public static let pill = dynamic(light: 0xE6E0D4, dark: 0x201C19)    // MBX.pill
    public static let pillDown = dynamic(light: 0xDCD5C7, dark: 0x2B2622) // MBX.pillDown
    public static let pri = dynamic(light: 0x0B0A09, dark: 0xECE6DA)     // MBX.pri
    public static let priInk = dynamic(light: 0xF6F3ED, dark: 0x0B0A09)  // MBX.priInk
    public static let priDown = dynamic(light: 0x2A2521, dark: 0xFFFAF2) // MBX.priDown
    public static let ok = dynamic(light: 0x15803D, dark: 0x4ADE80)
    public static let warn = dynamic(light: 0xA16207, dark: 0xFBBF24)
    public static let danger = dynamic(light: 0xB91C1C, dark: 0xF87171)  // MBX.bad

    static func dynamic(light: UInt32, dark: UInt32) -> Color {
        #if canImport(UIKit)
        Color(UIColor { $0.userInterfaceStyle == .dark ? UIColor(hex: dark) : UIColor(hex: light) })
        #elseif canImport(AppKit)
        // The Mac app: light and dark follow the system appearance, as on iPhone.
        Color(NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(hex: dark) : NSColor(hex: light)
        })
        #else
        Color(hex: dark)
        #endif
    }
}

#if !canImport(UIKit) && canImport(AppKit)
import AppKit

extension NSColor {
    convenience init(hex: UInt32) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
}
#endif

/// Radii in points (MBX.R).
public enum Radius {
    public static let input: CGFloat = 8, row: CGFloat = 14, tile: CGFloat = 16, image: CGFloat = 18
    public static let card: CGFloat = 22, menu: CGFloat = 24, frame: CGFloat = 28
}

public extension Color {
    init(hex: UInt32) {
        self.init(red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
    }
}

#if canImport(UIKit)
extension UIColor {
    convenience init(hex: UInt32) {
        self.init(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
}
#endif

/// Outfit for text, Big Shoulders Display for headings, Geist Mono for numbers (all SIL OFL 1.1).
/// Outfit and Geist Mono are variable fonts: they register as "Outfit-Thin" and "GeistMono-Regular", so
/// `.custom("Outfit")` would silently fall back to SF. Weights are set on the `wght` axis instead.
public enum FFFont {
    nonisolated(unsafe) private static var registered = false

    public static func register() {
        guard !registered else { return }
        registered = true
        for name in ["Outfit-Variable", "GeistMono-ASCII", "BigShouldersDisplay-800", "BigShouldersDisplay-900"] {
            if let url = Bundle.module.url(forResource: name, withExtension: "ttf") {
                CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
            }
        }
    }

    static func wght(_ w: Font.Weight) -> Double {
        switch w {
        case .ultraLight: 200
        case .thin: 100
        case .light: 300
        case .medium: 500
        case .semibold: 600
        case .bold: 700
        case .heavy: 800
        case .black: 900
        default: 400
        }
    }

    /// A CoreText font on a variable axis, scaled for Dynamic Type at the time it is made (`scales` false: the size as
    /// given, which is the size at the large text size).
    static func variableCT(_ postScriptName: String, _ size: CGFloat, _ weight: Font.Weight, _ style: Font.TextStyle,
                           scales: Bool = true) -> CTFont {
        register()
        #if canImport(UIKit)
        let scaled = scales ? UIFontMetrics(forTextStyle: uiStyle(style)).scaledValue(for: size) : size
        #else
        let scaled = size
        #endif
        let axis = [NSNumber(value: 0x7767_6874): NSNumber(value: wght(weight))]  // 'wght'
        let desc = CTFontDescriptorCreateWithAttributes([kCTFontNameAttribute: postScriptName,
                                                         kCTFontVariationAttribute: axis] as CFDictionary)
        return CTFontCreateWithFontDescriptor(desc, scaled, nil)
    }

    public static func text(_ size: CGFloat, _ weight: Font.Weight = .regular, relativeTo style: Font.TextStyle = .body) -> Font {
        Font(variableCT("Outfit-Thin", size, weight, style))
    }

    /// Outfit at a fixed size, for the keyboard's keys: like Apple's keyboard, they stay at the large text size.
    /// `.dynamicTypeSize(...large)` does not reach `text`: UIFontMetrics scales that font from the person's text size
    /// when it is made, before SwiftUI's environment applies.
    public static func fixed(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        Font(fixedCT(size, weight))
    }

    /// The CoreText font behind `fixed` (layout checks measure text with it).
    public static func fixedCT(_ size: CGFloat, _ weight: Font.Weight = .regular) -> CTFont {
        variableCT("Outfit-Thin", size, weight, .body, scales: false)
    }

    public static func display(_ size: CGFloat, black: Bool = true, relativeTo style: Font.TextStyle = .largeTitle) -> Font {
        .custom(black ? "BigShouldersDisplay-Black" : "BigShouldersDisplay-ExtraBold", size: size, relativeTo: style)
    }

    public static func mono(_ size: CGFloat, _ weight: Font.Weight = .medium) -> Font {
        Font(variableCT("GeistMono-Regular", size, weight, .body))
    }

    #if canImport(UIKit)
    /// UIKit copy of `text` for navigation bars and the keyboard.
    public static func uiText(_ size: CGFloat, _ weight: Font.Weight = .regular, relativeTo style: Font.TextStyle = .body) -> UIFont {
        variableCT("Outfit-Thin", size, weight, style) as UIFont
    }

    static func uiStyle(_ style: Font.TextStyle) -> UIFont.TextStyle {
        switch style {
        case .largeTitle: .largeTitle
        case .title: .title1
        case .title2: .title2
        case .title3: .title3
        case .headline: .headline
        case .subheadline: .subheadline
        case .callout: .callout
        case .footnote: .footnote
        case .caption: .caption1
        case .caption2: .caption2
        default: .body
        }
    }
    #endif
}

/// Card: filled paper-2, radius 22, no stroke (MBX mbxCard).
public struct Card: ViewModifier {
    public init() {}
    public func body(content: Content) -> some View {
        content
            .padding(18)
            .background(Palette.surface, in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
    }
}

public extension View {
    func ffCard() -> some View { modifier(Card()) }
    /// The only stroke there is: 1 pt on all four sides, following the corners.
    func ffStroke(_ radius: CGFloat, _ color: Color = Palette.lineStrong) -> some View {
        overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(color, lineWidth: 1))
    }
    /// Small uppercase label above sections (MBX tag level).
    func ffEyebrow() -> some View {
        self.font(FFFont.text(12.5, .semibold, relativeTo: .caption)).tracking(1.1).textCase(.uppercase).foregroundStyle(Palette.faint)
    }
}

/// Pill buttons as on the homepage: filled capsules, no stroke. One primary per screen.
public struct FFButtonStyle: ButtonStyle {
    public enum Kind { case primary, secondary, danger, ember }
    let kind: Kind
    public init(_ kind: Kind = .primary) { self.kind = kind }
    public func makeBody(configuration: Configuration) -> some View {
        let down = configuration.isPressed
        let fill: Color = switch kind {
        case .primary: down ? Palette.priDown : Palette.pri
        case .ember: Palette.brand.opacity(down ? 0.85 : 1)
        case .secondary, .danger: down ? Palette.pillDown : Palette.pill
        }
        let ink: Color = switch kind {
        case .primary: Palette.priInk
        case .ember: Palette.accentInk
        case .danger: Palette.danger
        case .secondary: Palette.fg
        }
        configuration.label
            .font(FFFont.text(16, kind == .primary || kind == .ember ? .semibold : .medium, relativeTo: .headline))
            .lineLimit(2)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 22)
            .frame(minHeight: 50)
            .foregroundStyle(ink)
            .background(fill, in: Capsule(style: .continuous))
            .contentShape(Capsule())
            .animation(.easeOut(duration: 0.15), value: down)
    }
}
