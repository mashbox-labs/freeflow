import Foundation

/// How dictated text is written. Each style is a fixed set of on-device rules.
public enum DictationStyle: String, CaseIterable, Codable, Identifiable, Sendable {
    case formal, casual, veryCasual, excited
    public var id: String { rawValue }

    /// The pill label, written in its own style.
    public var pill: String {
        switch self {
        case .formal: return "Formal."
        case .casual: return "Casual"
        case .veryCasual: return "very casual"
        case .excited: return "Excited!"
        }
    }
    public var summary: String {
        switch self {
        case .formal: return "Capitals and full punctuation."
        case .casual: return "Capitals, lighter punctuation."
        case .veryCasual: return "No capitals, lighter punctuation."
        case .excited: return "Capitals and exclamation marks."
        }
    }
    public var example: String {
        switch self {
        case .formal: return "Hey, are you free for lunch tomorrow? Let's do 12."
        case .casual: return "Hey are you free for lunch tomorrow? Let's do 12"
        case .veryCasual: return "hey are you free for lunch tomorrow? let's do 12"
        case .excited: return "Hey, are you free for lunch tomorrow? Let's do 12!"
        }
    }
    public var next: DictationStyle {
        let all = Self.allCases
        return all[(all.firstIndex(of: self)! + 1) % all.count]
    }
}
