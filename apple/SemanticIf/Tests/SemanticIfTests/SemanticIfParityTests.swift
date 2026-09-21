// cd apple/SemanticIf && swift test
//
// Issue #13 acceptance gate: parity against Semif's published BF16 results.
// The fixture-integrity tests run without the checkpoint; the scoring gate is
// opt-in like the #12 pinned-checkpoint test — set SEMIF_MODEL_DIR to a HubApi
// download base holding the snapshot (e.g. /tmp/semif10-harness/models).

import Foundation
import XCTest

import SemanticIfParity
@testable import SemanticIf

final class SemanticIfParityTests: XCTestCase {
    static let fixturesURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // SemanticIfTests/
        .deletingLastPathComponent()  // Tests/
        .deletingLastPathComponent()  // package root
        .appending(path: "Fixtures", directoryHint: .isDirectory)

    // MARK: - fixture integrity (no checkpoint needed)

    /// Every fixture's SHA-256 equals the sum pinned in the harness; the pins
    /// trace back to Semif's published `docs/media/SHA256SUMS` and
    /// `results/mlx/SHA256SUMS` (see Fixtures/README.md).
    func testFixtureHashesMatchPublishedSums() throws {
        for set in SemifParity.sets {
            XCTAssertNoThrow(try SemifParity.verifyFixtures(set, fixturesDir: Self.fixturesURL))
        }
    }

    /// The recorded rows parse, cover every input row 1:1 by id, and declare
    /// the same option ids in the same order.
    func testRecordedRowsCoverEveryInputRow() throws {
        let expectations: [String: Int] = ["decisions": 3, "authored144": 144]
        for set in SemifParity.sets {
            let (rows, recorded) = try SemifParity.load(set, fixturesDir: Self.fixturesURL)
            XCTAssertEqual(rows.count, expectations[set.name], set.name)
            XCTAssertEqual(recorded.count, rows.count, set.name)
            for row in rows {
                let reference = try XCTUnwrap(recorded[row.id], "\(set.name)/\(row.id)")
                XCTAssertEqual(reference.optionIDs, row.options.map(\.id), "\(set.name)/\(row.id)")
                XCTAssertEqual(reference.probabilities.count, row.options.count, "\(set.name)/\(row.id)")
                XCTAssertEqual(reference.probabilities.reduce(0, +), 1, accuracy: 1e-9, "\(set.name)/\(row.id)")
                XCTAssertEqual(reference.promptVersion, "direct-options-v1", "\(set.name)/\(row.id)")
            }
        }
    }

    // MARK: - opt-in pinned checkpoint gate

    /// The acceptance gate itself: score every fixture row on the pinned
    /// checkpoint and require 100 % prompt-hash equality, 100 % argmax
    /// agreement, and max |Δp| within `SemifParity.tolerance`. The full
    /// per-row report prints to stdout; it is also archived in
    /// `Fixtures/PARITY.md`.
    func testParityAgainstPublishedBF16Results() async throws {
        let base = ProcessInfo.processInfo.environment["SEMIF_MODEL_DIR"].map(URL.init(fileURLWithPath:))
            ?? SemanticIfModel.defaultDownloadBase()
        let snapshot = base.appending(path: "models/Qwen/Qwen3.5-4B")
        guard FileManager.default.fileExists(atPath: snapshot.appending(path: "config.json").path) else {
            throw XCTSkip("pinned checkpoint not cached at \(snapshot.path); set SEMIF_MODEL_DIR to opt in")
        }
        let model = try await SemanticIfModel(downloadBase: base)
        for set in SemifParity.sets {
            let report = try await SemifParity.run(set, model: model, fixturesDir: Self.fixturesURL)
            print(report.render(tolerance: SemifParity.tolerance))
            XCTAssertEqual(report.promptHashEquality, 1, "\(set.name): prompt-hash equality must be 100 %")
            XCTAssertEqual(report.inputTokensEquality, 1, "\(set.name): input-token counts must match")
            XCTAssertEqual(report.argmaxAgreement, 1, "\(set.name): argmax agreement must be 100 %")
            XCTAssertLessThanOrEqual(
                report.maxDeltaP, SemifParity.tolerance,
                "\(set.name): max |Δp| \(report.maxDeltaP) exceeds tolerance \(SemifParity.tolerance)")
        }
    }
}
