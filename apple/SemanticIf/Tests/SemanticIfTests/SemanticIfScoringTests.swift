// cd apple/SemanticIf && swift test
//
// Protocol and margin-policy tests for the scoring interface (issue #14).
// The policy is exercised through a scripted `LanguageModel` (same seam as
// the issue #12 readout tests) and against the published BF16 fixture rows,
// which pin the evidence the default threshold was tuned on. No checkpoint
// is needed.

import Foundation
import XCTest

@testable import SemanticIf

final class SemanticIfScoringTests: XCTestCase {
    static let fixturesURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // SemanticIfTests/
        .deletingLastPathComponent()  // Tests/
        .deletingLastPathComponent()  // package root
        .appending(path: "Fixtures")

    // MARK: - the margin policy

    /// At or above the threshold the argmax option wins; the smallest gap
    /// below it does not. The boundary itself decides (>=, not >).
    func testMarginPolicyThresholdBoundary() {
        XCTAssertEqual(
            SemanticIfMarginPolicy.decision(margin: 0.5, argmaxOptionID: "yes"),
            .option("yes"))
        XCTAssertEqual(
            SemanticIfMarginPolicy.decision(margin: SemanticIfMarginPolicy.defaultThreshold, argmaxOptionID: "yes"),
            .option("yes"))
        XCTAssertEqual(
            SemanticIfMarginPolicy.decision(margin: SemanticIfMarginPolicy.defaultThreshold - 0.001, argmaxOptionID: "yes"),
            .uncertain)
        XCTAssertEqual(
            SemanticIfMarginPolicy.decision(margin: 0, argmaxOptionID: "yes"),
            .uncertain)
    }

    /// A custom threshold is honored, so the policy stays tunable without an
    /// edit; the default remains the single fixture-tuned constant.
    func testMarginPolicyCustomThreshold() {
        XCTAssertEqual(
            SemanticIfMarginPolicy.decision(margin: 0.03, argmaxOptionID: "a", threshold: 0.03),
            .option("a"))
        XCTAssertEqual(
            SemanticIfMarginPolicy.decision(margin: 0.5, argmaxOptionID: "a", threshold: 0.6),
            .uncertain)
    }

    /// The default threshold must stay above the largest deviation observed
    /// in the parity gate (0.1152, PARITY.md) and must mark exactly the 7
    /// near-tie fixture rows uncertain — the evidence the default was tuned
    /// on. If a future checkpoint moves these numbers, retune deliberately.
    func testDefaultThresholdMatchesParityFixtureEvidence() throws {
        var margins: [Double] = []
        for fixture in ["decisions-bf16.jsonl", "authored144-bf16.jsonl"] {
            let url = Self.fixturesURL.appending(path: fixture)
            for line in try String(contentsOf: url, encoding: .utf8).split(separator: "\n", omittingEmptySubsequences: true) {
                let row = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
                let probabilities = try XCTUnwrap(row["probabilities"] as? [Double]).sorted(by: >)
                margins.append(probabilities[0] - probabilities[1])
            }
        }
        XCTAssertEqual(margins.count, 147)
        XCTAssertEqual(margins.filter { $0 < SemanticIfMarginPolicy.defaultThreshold }.count, 7)
        XCTAssertGreaterThan(SemanticIfMarginPolicy.defaultThreshold, 0.1152)
        XCTAssertEqual(margins.min() ?? 1, 0.059, accuracy: 0.001)
    }

    // MARK: - through the protocol

    /// A clear winner crosses the protocol as `.option(argmax)` with the
    /// readout's probabilities and diagnostics attached.
    func testProtocolScoreDecidesAboveThreshold() async throws {
        // p(A) - p(B) = 0.761 > 0.12.
        let scorer: any SemanticIfScoring = Self.makeScorer(topLogit: 3, runnerUpLogit: 1)
        let result = try await scorer.score(Self.sampleRow())
        XCTAssertEqual(result.rowID, "fixture-1")
        XCTAssertEqual(result.decision, .option("a"))
        XCTAssertEqual(result.argmaxOptionID, "a")
        XCTAssertEqual(result.threshold, SemanticIfMarginPolicy.defaultThreshold)
        XCTAssertEqual(result.probabilities.count, 2)
        XCTAssertEqual(result.probabilities.values.reduce(0, +), 1, accuracy: 1e-5)
        XCTAssertEqual(result.score.promptVersion, "direct-options-v1")
    }

    /// A near-tie crosses the protocol as `.uncertain`, so the caller routes
    /// to `needsInput` — even though the readout still reports an argmax.
    func testProtocolScoreUncertainBelowThreshold() async throws {
        // softmax([1, 0.9]) ≈ [0.525, 0.475]: margin 0.050 < 0.12.
        let scorer: any SemanticIfScoring = Self.makeScorer(topLogit: 1, runnerUpLogit: 0.9)
        let result = try await scorer.score(Self.sampleRow())
        XCTAssertEqual(result.decision, .uncertain)
        XCTAssertEqual(result.argmaxOptionID, "a")
        XCTAssertEqual(result.margin, 0.050, accuracy: 0.001)
    }

    /// `SemanticIfRow` adapts to the port's decision type field-for-field, so
    /// scoring through the protocol is scoring the same prompt.
    func testRowAdaptsToDecisionVerbatim() async throws {
        let row = Self.sampleRow()
        let decision = row.decision
        XCTAssertEqual(decision.id, row.id)
        XCTAssertEqual(decision.state, row.state)
        XCTAssertEqual(decision.question, row.question)
        XCTAssertEqual(decision.options, row.options)
        XCTAssertEqual(SemanticIfRow(decision), row)
    }

    /// The backend seam: anything conforming to `SemanticIfScoring` can stand
    /// in, which is how a llama.cpp sidecar (Route A) plugs in later.
    func testProtocolAcceptsMockBackend() async throws {
        let mock = MockScorer(result: SemanticIfResult(
            score: SemanticIfScore(
                rowID: "fixture-1",
                probabilities: ["a": 0.7, "b": 0.3],
                argmaxOptionID: "a",
                margin: 0.4,
                optionLogits: [1, 0],
                inputTokens: 0,
                forwardSeconds: 0,
                totalSeconds: 0,
                promptHash: "mock",
                peakMemoryBytes: 0)))
        let scorer: any SemanticIfScoring = mock
        let result = try await scorer.score(Self.sampleRow())
        XCTAssertEqual(result.decision, .option("a"))
        XCTAssertEqual(result.promptHash, "mock")
    }

    // MARK: - helpers

    /// A `.mlx` scorer over the scripted model: letter A's slot logit is
    /// `topLogit`, letter B's is `runnerUpLogit`, everything else is -10.
    static func makeScorer(topLogit: Float, runnerUpLogit: Float) -> SemanticIfModel {
        var logits = [Float](repeating: -10, count: FixtureLanguageModel.vocabSize)
        logits[65] = topLogit
        logits[66] = runnerUpLogit
        return SemanticIfModelTests.makeModel(slotLogits: logits).0
    }

    static func sampleRow() -> SemanticIfRow {
        SemanticIfRow(SemanticIfModelTests.sampleRow())
    }
}

/// A canned scorer proving the protocol boundary needs no MLX.
struct MockScorer: SemanticIfScoring {
    var result: SemanticIfResult

    func score(_ row: SemanticIfRow) async throws -> SemanticIfResult {
        result
    }
}

private extension SemanticIfResult {
    var promptHash: String { score.promptHash }
}
