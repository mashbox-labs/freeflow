#if targetEnvironment(macCatalyst)
import CoreFoundation

/// The macOS setting that matters to fn (the same check as the Mac app before build 20, Mac/MacDictation.swift).
enum FnKeySetting {
    /// What macOS does on its own when fn (the Globe key) is pressed: System Settings > Keyboard > "Press fn key to".
    /// 0 = Do Nothing. nil = never changed (the macOS default, which is not Do Nothing).
    static var usage: Int? {
        CFPreferencesCopyAppValue("AppleFnUsageType" as CFString, "com.apple.HIToolbox" as CFString) as? Int
    }

    /// One line for setup when fn also does something of its own, else nil.
    static var note: String? {
        switch usage {
        case 0: return nil
        case 1: return "fn also changes the input source on this Mac. In Keyboard settings, set \"Press fn key to\" to Do Nothing."
        case 2: return "fn also opens Emoji & Symbols on this Mac. In Keyboard settings, set \"Press fn key to\" to Do Nothing."
        case 3: return "fn also starts Apple's dictation on this Mac. In Keyboard settings, set \"Press fn key to\" to Do Nothing."
        default: return "Pressing fn on its own can also open emoji or change the input source. In Keyboard settings, set \"Press fn key to\" to Do Nothing."
        }
    }
}
#endif
