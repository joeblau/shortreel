// cd apple/SemanticIf && swift test  (skips unless SEMIF_MODEL_DIR is set)
//
// Opt-in real-checkpoint test for the account-step classifier rows (issue
// #15): scores the golden OCR fixtures in apple/Tests/Fixtures/AccountOCR with
// the pinned Qwen3.5-4B checkpoint. Skipped by default; set SEMIF_MODEL_DIR to
// the Hub snapshot root (e.g. ~/Library/Application Support/ShortReel/huggingface)
// to run it. The row-building strings come from apple/Contracts/warmup-tasks.json
// at test time so this test cannot drift from the app's classifier.

import Foundation
import XCTest

@testable import SemanticIf

final class SemanticIfAccountCheckTests: XCTestCase {
    struct Fixture: Decodable {
        struct Region: Decodable {
            let text: String
            let x: Double
            let y: Double
        }
        let platform: String
        let handle: String
        let outcome: String
        let regions: [Region]
    }

    struct Contract: Decodable {
        struct Step: Decodable {
            let id: String
            let successCriteria: [String]
            struct FailureMode: Decodable { let id: String; let detection: String }
            let failureModes: [FailureMode]
        }
        struct Activity: Decodable { let steps: [Step] }
        struct Platform: Decodable {
            let accountLocation: String
            let activities: [String: Activity]
        }
        let platforms: [String: Platform]
    }

    /// apple/, from this file at apple/SemanticIf/Tests/SemanticIfTests/.
    static let appleRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // SemanticIfTests/
        .deletingLastPathComponent()  // Tests/
        .deletingLastPathComponent()  // SemanticIf/
        .deletingLastPathComponent()  // apple/

    func testAccountFixturesWithRealCheckpoint() async throws {
        guard let dir = ProcessInfo.processInfo.environment["SEMIF_MODEL_DIR"], !dir.isEmpty else {
            throw XCTSkip("SEMIF_MODEL_DIR is not set; the checkpoint-backed account fixture test is opt-in.")
        }
        let contract = try JSONDecoder().decode(Contract.self,
            from: Data(contentsOf: Self.appleRoot.appending(path: "Contracts/warmup-tasks.json")))
        let scorer: any SemanticIfScoring = try await SemanticIfModel(
            downloadBase: URL(fileURLWithPath: dir))
        let fixturesURL = Self.appleRoot.appending(path: "Tests/Fixtures/AccountOCR")
        for name in try FileManager.default.contentsOfDirectory(atPath: fixturesURL.path)
            .filter({ $0.hasSuffix(".json") }).sorted()
        {
            let fixture = try JSONDecoder().decode(Fixture.self,
                from: Data(contentsOf: fixturesURL.appending(path: name)))
            let row = try Self.row(for: fixture, contract: contract)
            let result = try await scorer.score(row)
            switch fixture.outcome {
            case "unreadable":
                // Either an explicit unreadable verdict or a below-margin
                // near-tie routes to the contract's recovery.
                XCTAssertTrue(result.decision == .option("unreadable") || result.decision == .uncertain,
                    "\(name): expected unreadable/uncertain, got \(result.decision) (margin \(result.margin))")
            default:
                XCTAssertEqual(result.decision, .option(fixture.outcome),
                    "\(name): probabilities \(result.probabilities), margin \(result.margin)")
            }
        }
    }

    /// Mirrors `WarmUpAccountClassifier.row`: same question, same options,
    /// same state shape — sourced from the contract file.
    static func row(for fixture: Fixture, contract: Contract) throws -> SemanticIfRow {
        let platform = try XCTUnwrap(contract.platforms[fixture.platform])
        let account = try XCTUnwrap(platform.activities["watch"]?.steps.first { $0.id == "account" })
        let question = account.successCriteria.dropFirst().joined(separator: "; ")
        func detection(_ id: String) throws -> String {
            try XCTUnwrap(account.failureModes.first { $0.id == id }).detection
        }
        let ocrText = fixture.regions
            .sorted { ($0.y, $0.x) < ($1.y, $1.x) }
            .map(\.text)
        return SemanticIfRow(
            id: "warmup.account.\(fixture.platform.lowercased())",
            state: .object([
                ("platform", .string(fixture.platform)),
                ("expectedHandle", .string("@" + fixture.handle)),
                ("accountLocation", .string(platform.accountLocation)),
                ("ocrText", .array(ocrText.map { .string($0) })),
            ]),
            question: question,
            options: [
                .init(id: "matches", description: question),
                .init(id: "mismatch", description: try detection("handle-mismatch")),
                .init(id: "signed-out", description: try detection("signed-out")),
                .init(id: "unreadable", description: try detection("handle-unreadable")),
            ])
    }
}
