// SEMIF_MODEL_DIR=/tmp/semif10-harness/models swift run --package-path apple/SemanticIf semif-parity
//
// Prints the issue #13 parity report: the Swift scorer on the pinned
// Qwen3.5-4B checkpoint vs Semif's published BF16 rows, per row and per set.
// Exits nonzero if any set fails the gate. SEMIF_FIXTURES_DIR overrides the
// fixture location; SEMIF_MODEL_DIR selects the HubApi download base holding
// the pinned snapshot (default: ShortReel's Application Support cache).

import Foundation
import SemanticIf
import SemanticIfParity

let environment = ProcessInfo.processInfo.environment
let fixturesDir = environment["SEMIF_FIXTURES_DIR"].map(URL.init(fileURLWithPath:))
    // Sources/semif-parity/main.swift -> package root -> Fixtures
    ?? URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appending(path: "Fixtures", directoryHint: .isDirectory)
let modelBase = environment["SEMIF_MODEL_DIR"].map(URL.init(fileURLWithPath:))
    ?? SemanticIfModel.defaultDownloadBase()

print("loading \(SemanticIfModel.modelID) @ \(SemanticIfModel.checkpointRevision)")
let model = try await SemanticIfModel(downloadBase: modelBase)

var allPass = true
for set in SemifParity.sets {
    let report = try await SemifParity.run(set, model: model, fixturesDir: fixturesDir)
    print(report.render(tolerance: SemifParity.tolerance))
    allPass = allPass && report.passes(tolerance: SemifParity.tolerance)
}
print(allPass ? "GATE: PASS" : "GATE: FAIL")
exit(allPass ? 0 : 1)
