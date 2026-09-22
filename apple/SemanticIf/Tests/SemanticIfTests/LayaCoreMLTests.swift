import CoreML
import Foundation
import XCTest
@testable import SemanticIf

final class LayaCoreMLTests: XCTestCase {
    struct Reference: Decodable { let modelRevision: String; let cases: [Case] }
    struct Case: Decodable {
        let id: String
        let rowJSON: String
        let segments: [String: [Int]]
        let ids: [Int]
        let markers: [Int]
        let paddedLength: Int
        let logits: [Float]
        let probabilities: [String: Double]
        let choice: String
        var row: SemanticIfRow {
            get throws { try SemanticIfRow(SemanticIfDecision(json: SemanticIfJSON.parse(rowJSON))) }
        }
    }
    static func references() throws -> Reference {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "laya-reference", withExtension: "json", subdirectory: "Fixtures"))
        return try JSONDecoder().decode(Reference.self, from: Data(contentsOf: url))
    }
    static let tokens = LayaPrompt.Tokens(cls: 2, sep: 1, pad: 0, mask: 4, maskText: "<mask>")
    static let lengths = [16, 32, 64, 96, 128, 192, 256, 384, 512, 768, 1024]

    func testPromptAndPaddingMatchUpstreamReference() throws {
        let reference = try Self.references()
        XCTAssertEqual(reference.modelRevision, LayaCoreMLModel.checkpointRevision)
        for fixture in reference.cases {
            let input = try LayaPrompt.prepare(fixture.row, tokens: Self.tokens,
                maxLength: 1024, headMaxLength: 256, lengths: Self.lengths, maxOptions: 32) { text in
                guard let ids = fixture.segments[text] else {
                    XCTFail("Unexpected tokenizer input for \(fixture.id): \(text)")
                    return []
                }
                return ids
            }
            XCTAssertEqual(input.ids, fixture.ids, fixture.id)
            XCTAssertEqual(input.markers, fixture.markers, fixture.id)
            XCTAssertEqual(input.paddedLength, fixture.paddedLength, fixture.id)
            let batch = try LayaCoreMLModel.batch(input, pad: 0, maxOptions: 32)
            let mask = try XCTUnwrap(batch.featureValue(for: "attention_mask")?.multiArrayValue)
            XCTAssertEqual((0..<mask.count).map { mask[$0].intValue },
                Array(repeating: 1, count: input.ids.count) + Array(repeating: 0, count: input.paddedLength - input.ids.count))
            let markers = try XCTUnwrap(batch.featureValue(for: "marker_mask")?.multiArrayValue)
            XCTAssertEqual((0..<markers.count).map { markers[$0].intValue },
                Array(repeating: 1, count: input.markers.count) + Array(repeating: 0, count: 32 - input.markers.count))
            let probabilities = try LayaPrompt.probabilities(logits: fixture.logits, temperature: 1)
            for (option, probability) in zip(try fixture.row.options, probabilities) {
                XCTAssertEqual(probability, try XCTUnwrap(fixture.probabilities[option.id]), accuracy: 0.0001)
            }
        }
    }

    func testRejectsOversizeEvidenceAndInvalidRows() throws {
        var row = try XCTUnwrap(Self.references().cases.first).row
        row.state = .string("oversize")
        XCTAssertThrowsError(try LayaPrompt.prepare(row, tokens: Self.tokens,
            maxLength: 1024, headMaxLength: 256, lengths: Self.lengths, maxOptions: 32,
            encode: { $0 == "oversize" ? Array(repeating: 42, count: 1024) : [42] })) {
                guard case LayaCoreMLError.inputTooLong = $0 else { return XCTFail("\($0)") }
        }
        row.options[1].id = row.options[0].id
        XCTAssertThrowsError(try LayaPrompt.prepare(row, tokens: Self.tokens,
            maxLength: 1024, headMaxLength: 256, lengths: Self.lengths, maxOptions: 32, encode: { _ in [42] })) {
                XCTAssertEqual($0 as? SemanticIfPromptError, .duplicateOptionIDs)
        }
    }

    func testCalibrationValidationAndUncertainRouting() throws {
        XCTAssertEqual(try LayaPrompt.temperature(count: 12, defaults: [1, 1, 1], buckets: ["choice:11+": 0.1006]), 0.5)
        XCTAssertEqual(try LayaPrompt.temperature(count: 4, defaults: [1, 1, 1], buckets: ["choice:3-5": 9]), 5)
        XCTAssertThrowsError(try LayaPrompt.temperature(count: 2, defaults: [.nan, 1, 1], buckets: [:]))
        XCTAssertThrowsError(try LayaPrompt.probabilities(logits: [1, .infinity], temperature: 1))
        XCTAssertThrowsError(try LayaPrompt.probabilities(logits: [1, 0], temperature: 0))
        XCTAssertEqual(SemanticIfMarginPolicy.decision(margin: 0.119, argmaxOptionID: "a"), .uncertain)
        XCTAssertEqual(SemanticIfMarginPolicy.decision(margin: 0.12, argmaxOptionID: "a"), .option("a"))
        XCTAssertEqual(SemanticIfMarginPolicy.decision(margin: .nan, argmaxOptionID: "a"), .uncertain)
        XCTAssertEqual(SemanticIfScorerBackend.allCases, [.layaCoreML])
    }

    func testCancelledLoadDoesNotAccessAssets() async throws {
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await LayaCoreMLModel(modelDirectory: URL(fileURLWithPath: "/missing-laya-model"))
        }
        do {
            _ = try await task.value
            XCTFail("Cancelled load unexpectedly succeeded")
        } catch is CancellationError { }
    }

    /// Runs the actual Swift tokenizer and Core ML graph against upstream outputs.
    func testNativeRuntimeMatchesPythonReference() async throws {
        guard let path = ProcessInfo.processInfo.environment["SHORTREEL_LAYA_MODEL_DIR"] else {
            throw XCTSkip("Set SHORTREEL_LAYA_MODEL_DIR to the pinned downloaded model.")
        }
        let model = try await LayaCoreMLModel(modelDirectory: URL(fileURLWithPath: path))
        for fixture in try Self.references().cases {
            let row = try fixture.row
            let input = try await model.prepare(row)
            XCTAssertEqual(input.ids, fixture.ids, fixture.id)
            XCTAssertEqual(input.markers, fixture.markers, fixture.id)
            let result = try await model.score(row)
            XCTAssertEqual(result.argmaxOptionID, fixture.choice, fixture.id)
            XCTAssertEqual(result.score.promptVersion, LayaPrompt.version)
            for (id, probability) in fixture.probabilities {
                XCTAssertEqual(try XCTUnwrap(result.probabilities[id]), probability, accuracy: 0.002, "\(fixture.id)/\(id)")
            }
        }
    }
}
