import Foundation

/// Build 32 (keyboard crash reports, builds 19 to 30): iOS can hand the keyboard a text document proxy whose
/// `documentIdentifier` is nil, though Swift declares it a non-optional UUID, and reading it then traps
/// (UUID._unconditionallyBridgeFromObjectiveC in KeyboardViewController.watchField). Read it through Objective-C
/// instead; nil means no field.
public enum FieldIdentity {
    public static func read(_ proxy: AnyObject) -> UUID? {
        let getter = NSSelectorFromString("documentIdentifier")
        guard let object = proxy as? NSObjectProtocol, object.responds(to: getter),
              let value = object.perform(getter)?.takeUnretainedValue() as? NSUUID else { return nil }
        return value as UUID
    }
}
