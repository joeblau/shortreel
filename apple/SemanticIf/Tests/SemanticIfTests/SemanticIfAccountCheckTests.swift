
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
        let ownProfile: Bool
        let regions: [Region]
        let visualEvidence: String?
    }

    static let appleRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()

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
                ocrText: fixture.regions.sorted { ($0.y, $0.x) < ($1.y, $1.x) }.map(\.text),
                visualEvidence: fixture.visualEvidence)
            let result = try await scorer.score(row)
            let readable = fixture.regions.filter { $0.confidence >= 0.6 }
            let handles = LayaAccountPrompt.headerHandles(readable.map { ($0.text, $0.y) }, platform: fixture.platform)
            XCTAssertEqual(LayaAccountPrompt.outcome(surface: result.decision,
                expectedHandle: fixture.handle, observedHandles: handles,
                signInControlsVisible: LayaAccountPrompt.hasSignInControls(readable.map(\.text)),
                ownProfileVisible: fixture.ownProfile), fixture.outcome,
                "\(name): probabilities \(result.probabilities), margin \(result.margin)")
        }
    }

}
