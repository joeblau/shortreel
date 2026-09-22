import CoreGraphics
import Foundation

// From apple/: swiftc -swift-version 6 SemanticIf/Sources/SemanticIf/{SemanticIfPrompt,SemanticIfScoring}.swift ShortReel/Services/DevicePrompts/{DevicePromptPlan,DevicePromptPlanner,PhoneVisionTypes,PhoneSubmissionGuard,WarmUpAccountClassifier}.swift Tests/WarmUpAccountClassifierTests.swift -o /tmp/shortreel-account-classifier-tests && /tmp/shortreel-account-classifier-tests
/// Account-step classifier tests (contract TASK-8, issue #15): golden OCR
/// fixtures per platform × outcome scored through a scripted SemanticIfScoring
/// stub — no MLX, no checkpoint.
@main
enum WarmUpAccountClassifierTests {
    enum Failure: Error { case assertion(String) }
    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw Failure.assertion(message) }
    }

    struct Fixture: Decodable {
        struct Region: Decodable {
            let text: String
            let confidence: Float
            let x: Double, y: Double, width: Double, height: Double
        }
        let platform: String
        let handle: String
        let outcome: String
        let regions: [Region]

        var textRegions: [PhoneSubmissionGuard.TextRegion] {
            regions.map {
                PhoneSubmissionGuard.TextRegion(text: $0.text, confidence: $0.confidence,
                    bounds: CGRect(x: $0.x, y: $0.y, width: $0.width, height: $0.height))
            }
        }
    }

    /// A scripted `SemanticIfScoring`: the given winner takes `winnerP`, the
    /// other options share the rest. It records every row so tests can inspect
    /// the state the classifier built from OCR.
    final class StubScorer: SemanticIfScoring, @unchecked Sendable {
        let winner: String
        let winnerP: Double
        private(set) var rows: [SemanticIfRow] = []

        init(winner: String, winnerP: Double = 0.7) {
            self.winner = winner
            self.winnerP = winnerP
        }

        func score(_ row: SemanticIfRow) async throws -> SemanticIfResult {
            rows.append(row)
            let losers = row.options.map(\.id).filter { $0 != winner }
            var probabilities = [winner: winnerP]
            for loser in losers { probabilities[loser] = (1 - winnerP) / Double(losers.count) }
            let runnerUp = probabilities.values.sorted(by: >).dropFirst().first ?? 0
            return SemanticIfResult(score: SemanticIfScore(
                rowID: row.id, probabilities: probabilities, argmaxOptionID: winner,
                margin: winnerP - runnerUp, optionLogits: [], inputTokens: 0,
                forwardSeconds: 0, totalSeconds: 0, promptHash: "stub-\(winner)", peakMemoryBytes: 0))
        }
    }

    static func main() async throws {
        try await goldenFixtures()
        try await belowMarginIsUnreadable()
        try rowContract()
        try await unknownOptionThrows()
        try observedHandleNormalization()
        print("Warm-up account classifier tests passed (5 scenarios, 16 golden fixtures)")
    }

    /// Every platform × outcome fixture classifies to its golden verdict, from
    /// a scored row carrying the fixture's OCR text, handle, and location.
    static func goldenFixtures() async throws {
        let names = ["tiktok", "instagram", "x", "youtube"]
            .flatMap { platform in ["matches", "mismatch", "signed-out", "unreadable"].map { "\(platform)-\($0)" } }
        for name in names {
            let fixture = try loadFixture(name)
            let scorer = StubScorer(winner: fixture.outcome)
            let decision = try await WarmUpAccountClassifier.classify(regions: fixture.textRegions,
                platform: fixture.platform, accountLocation: "test account location",
                handle: fixture.handle, scorer: scorer)
            try expect(decision.outcome.rawValue == fixture.outcome, "\(name): verdict \(decision.outcome) != \(fixture.outcome)")
            try expect(decision.promptHash == "stub-\(fixture.outcome)", "\(name): prompt hash not journaled")
            try expect(decision.probabilities.count == 4 && decision.margin > decision.threshold,
                "\(name): readout diagnostics missing")
            let row = try scorer.rows.first ?? { throw Failure.assertion("\(name): scorer never called") }()
            try expect(row.id == "warmup.account.\(fixture.platform.lowercased())", "\(name): row id drifted")
            try expect(row.question == WarmUpAccountClassifier.successCriteria, "\(name): question drifted")
            try expect(row.options.map(\.id) == WarmUpAccountClassifier.optionIDs, "\(name): option order drifted")
            guard case .object(let state) = row.state,
                  let ocr = state.first(where: { $0.0 == "ocrText" })?.1,
                  case .array(let lines) = ocr,
                  let expectedHandle = state.first(where: { $0.0 == "expectedHandle" })?.1,
                  case .string(let location) = state.first(where: { $0.0 == "accountLocation" })?.1 else {
                throw Failure.assertion("\(name): malformed state")
            }
            try expect(expectedHandle == .string("@\(fixture.handle)"), "\(name): expected handle not in state")
            try expect(location == "test account location", "\(name): accountLocation not in state")
            let texts = lines.compactMap { value -> String? in
                guard case .string(let text) = value else { return nil }
                return text
            }
            // OCR order in the prompt is top-to-bottom, not recognition order.
            let expectedOrder = fixture.regions
                .sorted { ($0.y, $0.x) < ($1.y, $1.x) }
                .map(\.text)
            try expect(texts == expectedOrder, "\(name): OCR regions lost or out of order")
            if fixture.outcome == "mismatch" {
                try expect(decision.evidence.contains("@jane.doe88") && decision.evidence.contains("@\(fixture.handle)"),
                    "\(name): mismatch evidence must name both handles")
            }
        }
    }

    /// A below-margin score is the contract's unreadable path even when the
    /// argmax is a real option; the runner owns the recovery from there.
    static func belowMarginIsUnreadable() async throws {
        let fixture = try loadFixture("tiktok-matches")
        // p(matches) = 0.30, others 0.2333: margin 0.0667 < 0.12 threshold.
        let scorer = StubScorer(winner: "matches", winnerP: 0.30)
        let decision = try await WarmUpAccountClassifier.classify(regions: fixture.textRegions,
            platform: fixture.platform, accountLocation: "test account location",
            handle: fixture.handle, scorer: scorer)
        try expect(decision.outcome == .unreadable, "Below-margin score did not route to the unreadable recovery")
        try expect(decision.margin < decision.threshold, "Margin diagnostics lost")
    }

    /// The row satisfies the Semif prompt contract: 2–16 options, unique ids,
    /// failure options carrying the contract's detection text.
    static func rowContract() throws {
        let row = try WarmUpAccountClassifier.row(platform: "TikTok",
            accountLocation: "Tap the Profile tab.", handle: "janedoe", ocrText: ["@janedoe"])
        try SemanticIfPrompt.validate(row.decision)
        try expect(row.options.count <= 16, "More than 16 options")
        let descriptions = Dictionary(uniqueKeysWithValues: row.options.map { ($0.id, $0.description) })
        for mode in WarmUpAccountClassifier.failureModes {
            let optionID = ["handle-mismatch": "mismatch", "signed-out": "signed-out", "handle-unreadable": "unreadable"][mode.id]!
            try expect(descriptions[optionID] == mode.detection, "\(optionID): detection text drifted from the contract")
        }
        try expect(descriptions["matches"] == WarmUpAccountClassifier.successCriteria, "matches: not the success criteria")
        do {
            _ = try WarmUpAccountClassifier.options(failureModes: [])
            throw Failure.assertion("Missing contract failure modes built a row anyway")
        } catch WarmUpAccountClassifier.ClassifierError.missingFailureMode { }
    }

    static func unknownOptionThrows() async throws {
        let fixture = try loadFixture("tiktok-matches")
        let scorer = StubScorer(winner: "bogus")
        do {
            _ = try await WarmUpAccountClassifier.classify(regions: fixture.textRegions,
                platform: fixture.platform, accountLocation: "test account location",
                handle: fixture.handle, scorer: scorer)
            throw Failure.assertion("An undeclared scorer option became a verdict")
        } catch WarmUpAccountClassifier.ClassifierError.unknownOption(let id) {
            try expect(id == "bogus", "Wrong unknown option id")
        }
    }

    static func observedHandleNormalization() throws {
        let regions = [
            PhoneSubmissionGuard.TextRegion(text: "Jane Doe", confidence: 0.9, bounds: CGRect(x: 0.3, y: 0.1, width: 0.2, height: 0.03)),
            PhoneSubmissionGuard.TextRegion(text: "  @Jane.Doe88 ", confidence: 0.9, bounds: CGRect(x: 0.3, y: 0.17, width: 0.2, height: 0.03)),
        ]
        try expect(WarmUpAccountClassifier.observedHandle(in: regions) == "jane.doe88", "Observed handle not normalized")
        try expect(WarmUpAccountClassifier.observedHandle(in: Array(regions.prefix(1))) == nil, "Handle invented without an @ token")
    }

    static func loadFixture(_ name: String) throws -> Fixture {
        let url = URL(fileURLWithPath: "Tests/Fixtures/AccountOCR/\(name).json")
        return try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
    }
}
