// cd apple/SemanticIf && swift test  (skips unless SHORTREEL_LAYA_MODEL_DIR is set)
//
// Opt-in real-checkpoint test for the account-step classifier rows (issue
// #15): scores the golden OCR fixtures in apple/Tests/Fixtures/AccountOCR with
// the pinned Laya Core ML checkpoint. Skipped by default; set SHORTREEL_LAYA_MODEL_DIR to
// the directory returned by hf download --local-dir. Uses the same account
// prompt and exact identifier comparison as the app.

import Foundation
import XCTest

@testable import SemanticIf

final class SemanticIfAccountCheckTests: XCTestCase {
    struct Fixture: Decodable {
        struct Region: Decodable {
            let text: String
            let x: Double
            let y: Double
            let confidence: Double
        }
        let platform: String
        let handle: String
        let outcome: String
        let regions: [Region]
    }

    /// apple/, from this file at apple/SemanticIf/Tests/SemanticIfTests/.
    static let appleRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // SemanticIfTests/
        .deletingLastPathComponent()  // Tests/
        .deletingLastPathComponent()  // SemanticIf/
        .deletingLastPathComponent()  // apple/

    func testAccountFixturesWithRealCheckpoint() async throws {
        guard let dir = ProcessInfo.processInfo.environment["SHORTREEL_LAYA_MODEL_DIR"], !dir.isEmpty else {
            throw XCTSkip("SHORTREEL_LAYA_MODEL_DIR is not set; the checkpoint-backed account fixture test is opt-in.")
        }
        let scorer: any SemanticIfScoring = try await LayaCoreMLModel(
            modelDirectory: URL(fileURLWithPath: dir))
        let fixturesURL = Self.appleRoot.appending(path: "Tests/Fixtures/AccountOCR")
        for name in try FileManager.default.contentsOfDirectory(atPath: fixturesURL.path)
            .filter({ $0.hasSuffix(".json") }).sorted()
        {
            let fixture = try JSONDecoder().decode(Fixture.self,
                from: Data(contentsOf: fixturesURL.appending(path: name)))
            let row = LayaAccountPrompt.row(platform: fixture.platform,
                ocrText: fixture.regions.sorted { ($0.y, $0.x) < ($1.y, $1.x) }.map(\.text))
            let result = try await scorer.score(row)
            let handles = fixture.regions.filter { $0.confidence >= 0.6 }.flatMap { LayaAccountPrompt.handles(in: $0.text) }
            XCTAssertEqual(LayaAccountPrompt.outcome(surface: result.decision,
                expectedHandle: fixture.handle, observedHandles: handles), fixture.outcome,
                "\(name): probabilities \(result.probabilities), margin \(result.margin)")
        }
    }

}
