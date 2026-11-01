/// The Mac's paste: one space before a dictation when the character just before the cursor is known, is
/// not whitespace or a newline, and the dictation does not already start with whitespace. The iOS keyboard's rule
/// (KeyboardViewController.insertDictation) on the Mac's Accessibility read. When the app does not expose the text before
/// the cursor (`before` is nil), nothing is added: never a guess. No other spacing, capitals or punctuation change.
/// Compiled into FreeFlowKit and, as is, into the Mac plug-in (scripts/generate-catalyst-project.py).
public enum LeadingSpace {
    public static func needed(before: Character?, text: String) -> Bool {
        guard let before, !before.isWhitespace, !before.isNewline, let first = text.first, !first.isWhitespace, !first.isNewline
        else { return false }
        return true
    }

    public static func apply(before: Character?, to text: String) -> String {
        needed(before: before, text: text) ? " " + text : text
    }
}
