import CoreGraphics
import Foundation

// The rest of Apple's keyboard (2026-10-30: about half of the classic keyboard was missing, including the third
// level needed to type a phone number): the #+= page, the
// layouts each kind of field asks for, long-press accents, caps lock, the double-space period, the return key's
// label and capitals at the start of a sentence. Every rule here is plain data so FreeFlowKit's tests cover it on macOS.

/// A page of keys under the Dictate row.
public enum KeyPage: String, Sendable, CaseIterable {
    /// a to z
    case letters
    /// Apple's 123 page: digits, - / : ; ( ) $ & @ ", and . , ? ! '
    case numbers
    /// Apple's #+= page: [ ] { } # % ^ * + =, _ \ | ~ < > € £ ¥ •, and . , ? ! '
    case symbols
    /// Number, decimal and phone fields: 1 to 9 and 0 in a grid of three
    case pad
    /// The phone pad's +*# page
    case padSymbols

    public var isPad: Bool { self == .pad || self == .padSymbols }

    /// The three rows above the bottom row (the z row's punctuation on the 123 and #+= pages).
    public var rows: [String] {
        switch self {
        case .letters: KeyGeometry.letterRows
        case .numbers: KeyGeometry.symbolRows
        case .symbols: KeyGeometry.moreSymbolRows
        case .pad, .padSymbols: []
        }
    }
}

public extension KeyGeometry {
    /// Apple's #+= page (iOS 27.2, English US).
    static let moreSymbolRows = ["[]{}#%^*+=", "_\\|~<>€£¥•", ".,?!'"]
}

/// What kind of text the field takes, from UITextDocumentProxy.keyboardType (raw values, so FreeFlowKit needs no UIKit:
/// 0 default, 1 asciiCapable, 2 numbersAndPunctuation, 3 URL, 4 numberPad, 5 phonePad, 6 namePhonePad, 7 emailAddress,
/// 8 decimalPad, 9 twitter, 10 webSearch, 11 asciiCapableNumberPad).
public enum KeyField: String, Sendable, CaseIterable {
    case text, numbersFirst, email, url, twitter, webSearch, numberPad, decimalPad, phonePad

    public init(keyboardType raw: Int) {
        switch raw {
        case 2: self = .numbersFirst
        case 3: self = .url
        case 4, 11: self = .numberPad
        case 5: self = .phonePad
        case 7: self = .email
        case 8: self = .decimalPad
        case 9: self = .twitter
        case 10: self = .webSearch
        default: self = .text   // default, asciiCapable, namePhonePad (letters first, as Apple's)
        }
    }

    /// The page the keyboard opens on in this field.
    public var firstPage: KeyPage {
        switch self {
        case .numberPad, .decimalPad, .phonePad: .pad
        case .numbersFirst: .numbers
        default: .letters
        }
    }

    /// Keys Apple puts on the bottom row of this field, between space and return (left to right).
    public var bottomExtras: [String] {
        switch self {
        case .email: ["@", "."]
        case .url: [".", "/", ".com"]
        case .twitter: ["@", "#"]
        case .webSearch: ["."]
        default: []
        }
    }

    /// URL fields have no space bar: their extras share the room.
    public var hasSpace: Bool { self != .url }
}

/// The return key's label from UITextDocumentProxy.returnKeyType (raw: 0 default, 1 go, 2 google, 3 join, 4 next,
/// 5 route, 6 search, 7 send, 8 yahoo, 9 done, 10 emergencyCall, 11 continue). nil = the plain return arrow.
public enum ReturnKeyLabel {
    public static func text(_ raw: Int) -> String? {
        switch raw {
        case 1: "go"
        case 2, 6, 8: "search"
        case 3: "join"
        case 4: "next"
        case 5: "route"
        case 7: "send"
        case 9: "done"
        case 10: "emergency call"
        case 11: "continue"
        default: nil
        }
    }

    /// iOS 26 and later draw search and send as symbols on a coloured key (iPhone Air simulators, iOS 27.2 and 26.5:
    /// magnifying glass, up arrow); the other words stay words.
    public static func symbol(_ raw: Int) -> String? {
        switch raw {
        case 2, 6, 8: "magnifyingglass"
        case 7: "arrow.up"
        default: nil
        }
    }

    /// Apple colours these return keys (the action the field takes); we use the brand orange.
    public static func prominent(_ raw: Int) -> Bool { [1, 2, 3, 5, 6, 7, 8, 9, 10, 11].contains(raw) }
}

/// Capitals where Apple's keyboard turns shift on by itself (UITextDocumentProxy.autocapitalizationType, raw:
/// 0 none, 1 words, 2 sentences, 3 allCharacters).
public enum AutoCapital {
    public static func wantsShift(before: String, mode: Int) -> Bool {
        switch mode {
        case 0: return false
        case 3: return true
        case 1: return before.isEmpty || before.last!.isWhitespace
        default:
            if before.isEmpty || before.last!.isNewline { return true }
            guard before.last!.isWhitespace else { return false }
            let text = before.trimmingCharacters(in: .whitespaces)
            guard let last = text.last else { return true }
            return last.isNewline || ".!?".contains(last)
        }
    }
}

/// Space twice quickly after a word types ". " (Apple's "." shortcut): the text before the second space ends in a
/// letter or digit and one space.
public enum DoubleSpace {
    public static let window: TimeInterval = 1.0

    public static func makesPeriod(before: String) -> Bool {
        guard before.hasSuffix(" "), !before.hasSuffix("  ") else { return false }
        guard let c = before.dropLast().last else { return false }
        return c.isLetter || c.isNumber
    }
}

/// A long-press panel: rows top to bottom, each left to right, the key's own character in the bottom row.
public struct CalloutPanel: Equatable, Sendable {
    public let rows: [[String]]
    /// The key's own character as a flat index into `options` (selected at first; a release with no movement types it).
    public let base: Int
    public var options: [String] { rows.flatMap { $0 } }
    /// Column of the key's own character in the bottom row.
    public var baseColumn: Int { base - rows.dropLast().reduce(0) { $0 + $1.count } }
}

/// Long-press panels as Apple's English (US) keyboard draws them on the iPhone Air simulator, iOS 27.2, read off
/// screenshots taken during 1.6 s holds of every letter (KeyboardMatchUITests + match/holdcap.py, 10-30): the same
/// characters in the same places, the key's own character among them over the key. q, p, f, j, x, v, b and m have
/// none. No outside data. "%" (on #+=) was not held.
public enum KeyCallouts {
    static let letters: [String: [[String]]] = [
        "a": [["æ", "ã", "å", "ā", "ă", "ą"], ["a", "à", "á", "â", "ä", "ǎ"]],
        "c": [["c", "ç", "ć", "č", "ċ"]],
        "d": [["d", "ď", "ð"]],
        "e": [["ë", "é", "e", "è", "ê", "ě", "ẽ", "ē", "ė", "ę"]],
        "g": [["g", "ğ", "ġ"]],
        "h": [["h", "ħ"]],
        "i": [["į", "ı", "ī", "ĩ", "ï", "í", "ì", "i", "î", "ǐ"]],
        "k": [["ķ", "k"]],
        "l": [["ľ", "ļ", "ł", "l"]],
        "n": [["ň", "ņ", "ń", "ñ", "n"]],
        "o": [["ő", "ō", "õ", "ø", "œ", "ǒ", "ö", "ó", "ò", "o", "ô"]],
        "r": [["r", "ř"]],
        "s": [["s", "ß", "ş", "ș", "ś", "š"]],
        "t": [["t", "ț", "ť", "þ"]],
        "u": [["ų", "ů", "ű", "ũ", "ü", "ú", "ù", "u", "û", "ǔ", "ū"]],
        "w": [["w", "ŵ"]],
        "y": [["ÿ", "ŷ", "ý", "y"]],
        "z": [["z", "ź", "ž", "ż"]],
    ]
    static let symbols: [String: [[String]]] = [
        "0": [["°", "0"]],
        "-": [["-", "–", "—", "•"]],
        "/": [["/", "\\"]],
        "$": [["₽", "¥", "€", "$", "¢", "£", "₩"]],
        "&": [["&", "§"]],
        "\"": [["«", "»", "„", "“", "”", "\""]],
        ".": [[".", "…"]],
        "?": [["?", "¿"]],
        "!": [["!", "¡"]],
        "'": [["`", "‘", "’", "'"]],
        "%": [["%", "‰"]],
    ]

    /// The panel for a key as shown, nil = no panel. Shifted letters give capitals; a character with no single
    /// capital of its own (ß, and ı whose capital is I) is left out.
    public static func panel(_ id: String, page: KeyPage, upper: Bool) -> CalloutPanel? {
        let rows: [[String]]
        switch page {
        case .letters:
            guard let r = letters[id] else { return nil }
            let base = id.uppercased()
            rows = upper ? r.map { $0.compactMap { c in
                let u = c.uppercased()
                return u.count == 1 && (c == id || u != base) ? u : nil
            } } : r
        case .numbers, .symbols:
            guard let r = symbols[id] else { return nil }
            rows = r
        case .pad, .padSymbols: return nil
        }
        let own = upper && page == .letters ? id.uppercased() : id
        guard let bottom = rows.last, let col = bottom.firstIndex(of: own) else { return nil }
        return CalloutPanel(rows: rows, base: rows.dropLast().reduce(0) { $0 + $1.count } + col)
    }

    /// The panel's characters in order (rows top to bottom), [] = no panel.
    public static func variants(_ id: String, page: KeyPage, upper: Bool) -> [String] {
        panel(id, page: page, upper: upper)?.options ?? []
    }
}

/// Where the long-press panel sits, as Apple's: its rows above the key, the key's own character over the key, the
/// panel kept inside the keyboard's width (it slides, so the character over the key can move off it at the edges).
public enum CalloutGeometry {
    public static let pad: Double = 4

    /// Cells in the order of `panel.options` and the panel around them.
    public static func layout(key: CGRect, panel p: CalloutPanel, width W: Double) -> (panel: CGRect, cells: [CGRect]) {
        let cols = p.rows.map(\.count).max() ?? 0
        guard cols > 0 else { return (.zero, []) }
        let cw = min(max(Double(key.width), 30) + 6, (W - 4 - 2 * pad) / Double(cols)), ch = Double(key.height) + 6
        let total = cw * Double(cols) + 2 * pad, height = ch * Double(p.rows.count) + 2 * pad
        var x0 = Double(key.midX) - cw * (Double(p.baseColumn) + 0.5) - pad
        x0 = min(max(2, x0), W - 2 - total)
        let y0 = max(2, Double(key.minY) - height - 4)
        var cells: [CGRect] = []
        for (r, row) in p.rows.enumerated() {
            for c in row.indices {
                cells.append(CGRect(x: x0 + pad + Double(c) * cw, y: y0 + pad + Double(r) * ch, width: cw, height: ch))
            }
        }
        return (CGRect(x: x0, y: y0, width: total, height: height), cells)
    }

    /// The character under the finger: the cell it is over, else the nearest one.
    public static func selected(at p: CGPoint, cells: [CGRect]) -> Int {
        guard !cells.isEmpty else { return 0 }
        if let i = cells.firstIndex(where: { $0.contains(p) }) { return i }
        func d(_ r: CGRect) -> Double {
            let dx = max(Double(r.minX) - Double(p.x), 0, Double(p.x) - Double(r.maxX))
            let dy = max(Double(r.minY) - Double(p.y), 0, Double(p.y) - Double(r.maxY))
            return dx * dx + dy * dy
        }
        return cells.indices.min { d(cells[$0]) < d(cells[$1]) } ?? 0
    }
}

/// The phone pad's digit captions.
public enum PadCaption {
    public static func letters(_ digit: String) -> String {
        ["2": "ABC", "3": "DEF", "4": "GHI", "5": "JKL", "6": "MNO", "7": "PQRS", "8": "TUV", "9": "WXYZ", "0": "+"][digit] ?? ""
    }
}
