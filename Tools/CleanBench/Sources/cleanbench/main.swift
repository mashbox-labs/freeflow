import Foundation
import CoreML
import FreeFlowKit
import FreeFlowRules
import FreeFlowTagger

// cleanbench --in FILE.jsonl --field text --out FILE.jsonl [--tagger cpu|ane|gpu|all]
// With --tagger the on-device disfluency tagger (Core ML) runs after the rules, as in the app.
// Runs the rules at every level on each row's text and records the time each call took.
let args = CommandLine.arguments
func arg(_ key: String, _ fallback: String) -> String {
    if let i = args.firstIndex(of: key), i + 1 < args.count { return args[i + 1] }
    return fallback
}
let inPath = arg("--in", "in.jsonl"), field = arg("--field", "text"), outPath = arg("--out", "out.jsonl")
let taggerUnits = arg("--tagger", "")
var scorer: DisfluencyScorer? = nil
if !taggerUnits.isEmpty {
    let units: MLComputeUnits = ["cpu": .cpuOnly, "ane": .cpuAndNeuralEngine, "gpu": .cpuAndGPU][taggerUnits] ?? .all
    let loadStart = DispatchTime.now().uptimeNanoseconds
    guard DisfluencyTagger.shared.load(computeUnits: units) else { print("tagger failed to load"); exit(1) }
    print(String(format: "tagger loaded (%@) in %.1f ms", taggerUnits, Double(DispatchTime.now().uptimeNanoseconds - loadStart) / 1e6))
    scorer = DisfluencyTagger.shared
}
let rows = try String(contentsOfFile: inPath, encoding: .utf8).split(separator: "\n")
    .compactMap { try JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
FileManager.default.createFile(atPath: outPath, contents: nil)
let out = try FileHandle(forWritingTo: URL(fileURLWithPath: outPath))
var worst = 0.0, total = 0.0, calls = 0
for row in rows {
    guard let text = row[field] as? String else { continue }
    var rec: [String: Any] = ["id": row["id"] ?? "", "input": text]
    let gateStart = DispatchTime.now().uptimeNanoseconds
    rec["english_rules"] = Cleanup.usesEnglishRules(text)
    rec["gate_us"] = Double(DispatchTime.now().uptimeNanoseconds - gateStart) / 1000
    for level in CleanupLevel.allCases {
        let start = DispatchTime.now().uptimeNanoseconds
        let cleaned = Cleanup.apply(text, level: level, scorer: scorer)
        let us = Double(DispatchTime.now().uptimeNanoseconds - start) / 1000
        worst = max(worst, us); total += us; calls += 1
        rec[level.rawValue] = cleaned
        rec[level.rawValue + "_us"] = us
        rec[level.rawValue + "_formal"] = TextFormatter.format(text, style: .formal, options: FormatOptions(cleanup: level, scorer: scorer))
        rec[level.rawValue + "_verycasual"] = TextFormatter.format(text, style: .veryCasual, options: FormatOptions(cleanup: level, scorer: scorer))
    }
    out.write(try JSONSerialization.data(withJSONObject: rec, options: [.sortedKeys])); out.write("\n".data(using: .utf8)!)
}
try out.close()
print(String(format: "%d rows, %d calls, mean %.1f us, worst %.1f us", rows.count, calls, total / Double(max(calls, 1)), worst))
