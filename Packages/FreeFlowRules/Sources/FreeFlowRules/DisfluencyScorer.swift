import FreeFlowKit
import Foundation

/// A model that scores each word of a line as disfluent or not. FreeFlowKit stays model-free; the app plugs in
/// the Core ML tagger (FreeFlowTagger). Keys: "O" keep, "R" reparandum (abandoned or corrected words),
/// "F" filler sound, "E" editing term, "D" discourse marker. Values are probabilities.
public protocol DisfluencyScorer: AnyObject, Sendable {
    func scores(words: [String]) -> [[String: Float]]?
    func threshold(for level: CleanupLevel) -> Float
}
