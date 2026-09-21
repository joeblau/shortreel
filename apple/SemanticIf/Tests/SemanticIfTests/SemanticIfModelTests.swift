// cd apple/SemanticIf && swift test
//
// Readout tests for the Semif scorer (issue #12). MLX cannot link from
// standalone `swiftc`, so these run under SPM against a scripted
// `LanguageModel`; the pinned-checkpoint test at the bottom is opt-in and
// skips unless the 8 GB snapshot is already on disk.

import Foundation
import MLX
import MLXLMCommon
import MLXNN
import XCTest

@testable import SemanticIf

final class SemanticIfModelTests: XCTestCase {
    /// The fixture rows shared with the standalone prompt tests.
    static let fixturesURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // SemanticIfTests/
        .deletingLastPathComponent()  // Tests/
        .deletingLastPathComponent()  // package root
        .appending(path: "Fixtures/decisions.jsonl")

    static func fixtureRows() throws -> [SemanticIfDecision] {
        try String(contentsOf: fixturesURL, encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { try SemanticIfDecision(json: SemanticIfJSON.parse(String($0))) }
    }

    /// Builds the scorer over a scripted model and the fixture tokenizer.
    static func makeModel(
        slotLogits: [Float],
        tokenizer: any MLXLMCommon.Tokenizer = FixtureTokenizer()
    ) -> (SemanticIfModel, FixtureLanguageModel) {
        let model = FixtureLanguageModel(slotLogits: slotLogits)
        let container = ModelContainer(
            context: ModelContext(
                configuration: ModelConfiguration(id: "semif-fixture"),
                model: model,
                processor: UnusedProcessor(),
                tokenizer: tokenizer))
        return (SemanticIfModel(container: container, tokenizer: SemanticIfTokenizer(tokenizer: tokenizer)), model)
    }

    // MARK: - the direct readout

    /// `score` gathers the last-position logits onto the declared answer
    /// slots, softmaxes them in Float32, and reports argmax and margin.
    func testScoreGathersSlotLogitsAndSoftmaxes() async throws {
        // Slot ids are the letter character codes: A=65, B=66, C=67.
        var logits = [Float](repeating: -10, count: FixtureLanguageModel.vocabSize)
        logits[65] = 1
        logits[66] = 3
        logits[67] = 2
        let (model, fixture) = Self.makeModel(slotLogits: logits)

        let row = SemanticIfDecision(
            id: "support-1",
            state: .string("The deployment completed at 14:02 UTC."),
            question: "Is there evidence that the deployment succeeded?",
            options: [
                .init(id: "yes", description: "The deployment succeeded."),
                .init(id: "no", description: "The deployment did not succeed."),
                .init(id: "unsure", description: "The evidence is insufficient."),
            ])
        let score = try await model.score(row)

        let weights = [exp(1 - 3), exp(0.0), exp(2 - 3)] as [Double]
        let total = weights.reduce(0, +)
        XCTAssertEqual(score.rowID, "support-1")
        XCTAssertEqual(score.optionLogits, [1, 3, 2])
        XCTAssertEqual(score.argmaxOptionID, "no")
        XCTAssertEqual(score.probabilities.count, 3)
        for (option, weight) in zip(row.options, weights) {
            XCTAssertEqual(score.probabilities[option.id] ?? -1, weight / total, accuracy: 1e-5)
        }
        XCTAssertEqual(score.margin, weights[1] / total - weights[2] / total, accuracy: 1e-5)
        XCTAssertEqual(score.promptVersion, "direct-options-v1")
        XCTAssertGreaterThan(score.totalSeconds, 0)
        XCTAssertEqual(fixture.forwardCount, 1)

        let rendered = try SemanticIfPrompt.applyQwen35ChatTemplate(SemanticIfPrompt.directMessages(row))
        XCTAssertEqual(score.inputTokens, rendered.count)
        XCTAssertEqual(score.promptHash, SemanticIfPrompt.digest(rendered))
    }

    /// Every fixture row scores through the mock, probabilities stay a
    /// distribution over the declared options, and argmax tracks the logits.
    func testFixtureRowsScoreAsDistributions() async throws {
        var logits = [Float](repeating: -10, count: FixtureLanguageModel.vocabSize)
        logits[65] = 0.5
        logits[66] = -1.5
        logits[67] = 2.5
        let (model, fixture) = Self.makeModel(slotLogits: logits)

        let rows = try Self.fixtureRows()
        XCTAssertEqual(rows.map(\.id), ["support-1", "route-1", "policy-1"])
        for row in rows {
            let score = try await model.score(row)
            XCTAssertEqual(score.rowID, row.id)
            XCTAssertEqual(score.probabilities.keys.sorted(), row.options.map(\.id).sorted())
            XCTAssertEqual(score.probabilities.values.reduce(0, +), 1, accuracy: 1e-5)
            XCTAssertEqual(score.argmaxOptionID, row.options[2].id)  // letter C holds the top logit
        }
        XCTAssertEqual(fixture.forwardCount, rows.count)
    }

    /// direct.py rejects non-finite scores; nothing is approximated.
    func testNonFiniteSlotLogitRejectsRow() async throws {
        var logits = [Float](repeating: 0, count: FixtureLanguageModel.vocabSize)
        logits[66] = .nan
        let (model, _) = Self.makeModel(slotLogits: logits)
        do {
            _ = try await model.score(Self.sampleRow())
            XCTFail("NaN slot logit must reject the row")
        } catch let error as SemanticIfModelError {
            XCTAssertEqual(error, .nonFiniteScores)
        }
    }

    /// An over-limit prompt is rejected by the prompt contract before any
    /// forward pass runs.
    func testOverLimitPromptSkipsForwardPass() async throws {
        let (model, fixture) = Self.makeModel(slotLogits: [Float](repeating: 0, count: FixtureLanguageModel.vocabSize))
        do {
            _ = try await model.score(Self.sampleRow(), maxTokens: 3)
            XCTFail("Over-limit prompt must reject the row")
        } catch let error as SemanticIfPromptError {
            guard case .inputTokensExceedLimit(let rowID, _, let maxTokens) = error else {
                return XCTFail("expected inputTokensExceedLimit, got \(error)")
            }
            XCTAssertEqual(rowID, "fixture-1")
            XCTAssertEqual(maxTokens, 3)
        }
        XCTAssertEqual(fixture.forwardCount, 0)
    }

    /// The tokenizer's chat template must reproduce the pinned rendering
    /// token-for-token; any drift rejects the row.
    func testChatTemplateMismatchRejectsRow() async throws {
        let (model, fixture) = Self.makeModel(
            slotLogits: [Float](repeating: 0, count: FixtureLanguageModel.vocabSize),
            tokenizer: MismatchedTemplateTokenizer())
        do {
            _ = try await model.score(Self.sampleRow())
            XCTFail("Template mismatch must reject the row")
        } catch let error as SemanticIfModelError {
            XCTAssertEqual(error, .chatTemplateMismatch)
        }
        XCTAssertEqual(fixture.forwardCount, 0)
    }

    // MARK: - the tokenizer adapter

    /// `SemanticIfTokenizer` maps to swift-transformers' calls exactly as
    /// Semif calls them: encode without special tokens, decode with special
    /// tokens kept, chat template proven equivalent to the pinned rendering.
    func testTokenizerAdapterMatchesSemifsCalls() throws {
        let adapter = SemanticIfTokenizer(tokenizer: FixtureTokenizer())
        XCTAssertEqual(adapter.encode("héllo"), [104, 233, 108, 108, 111])
        XCTAssertEqual(adapter.decode([104, 233, 108, 108, 111]), "héllo")
        let messages = try SemanticIfPrompt.directMessages(Self.sampleRow())
        XCTAssertEqual(
            try adapter.applyDirectChatTemplate(messages),
            try SemanticIfPrompt.applyQwen35ChatTemplate(messages))
        let mismatched = SemanticIfTokenizer(tokenizer: MismatchedTemplateTokenizer())
        XCTAssertThrowsError(try mismatched.applyDirectChatTemplate(messages)) {
            XCTAssertEqual($0 as? SemanticIfModelError, .chatTemplateMismatch)
        }
    }

    // MARK: - opt-in pinned checkpoint

    /// Runs the fixture rows through the real pinned Qwen3.5-4B checkpoint.
    /// Skips unless the snapshot is already on disk: set SEMIF_MODEL_DIR to a
    /// `HubApi` download base, or let it default to ShortReel's Application
    /// Support cache. Nothing is ever downloaded by the test suite.
    func testPinnedCheckpointScoresFixtureRows() async throws {
        let base = ProcessInfo.processInfo.environment["SEMIF_MODEL_DIR"].map(URL.init(fileURLWithPath:))
            ?? SemanticIfModel.defaultDownloadBase()
        let snapshot = base.appending(path: "models/Qwen/Qwen3.5-4B")
        guard FileManager.default.fileExists(atPath: snapshot.appending(path: "config.json").path) else {
            throw XCTSkip("pinned checkpoint not cached at \(snapshot.path); set SEMIF_MODEL_DIR to opt in")
        }
        let model = try await SemanticIfModel(downloadBase: base)
        for row in try Self.fixtureRows() {
            let score = try await model.score(row)
            XCTAssertEqual(score.probabilities.values.reduce(0, +), 1, accuracy: 1e-4)
            XCTAssertEqual(
                score.argmaxOptionID,
                row.options[score.optionLogits.enumerated().max(by: { $0.element < $1.element })!.offset].id)
            XCTAssertEqual(score.inputTokens ... 4096 ~= score.inputTokens, true)
        }
    }

    static func sampleRow() -> SemanticIfDecision {
        SemanticIfDecision(
            id: "fixture-1",
            state: .string("The deployment completed at 14:02 UTC."),
            question: "Is there evidence that the deployment succeeded?",
            options: [
                .init(id: "a", description: "First."),
                .init(id: "b", description: "Second."),
            ])
    }
}

/// One-token-per-unicode-scalar tokenizer over the `MLXLMCommon.Tokenizer`
/// seam. Its chat template renders via the pinned reference and encodes the
/// result, mirroring what swift-transformers does for Qwen3.5-4B — the
/// adapter proves the two agree on every call.
struct FixtureTokenizer: MLXLMCommon.Tokenizer {
    func encode(text: String, addSpecialTokens: Bool) -> [Int] {
        text.unicodeScalars.map { Int($0.value) }
    }

    func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String {
        tokenIds.compactMap { Unicode.Scalar($0).map(String.init) }.joined()
    }

    func convertTokenToId(_ token: String) -> Int? {
        token.unicodeScalars.count == 1 ? Int(token.unicodeScalars.first!.value) : nil
    }

    func convertIdToToken(_ id: Int) -> String? {
        Unicode.Scalar(id).map(String.init)
    }

    var bosToken: String? { nil }
    var eosToken: String? { nil }
    var unknownToken: String? { nil }

    func applyChatTemplate(
        messages: [[String: any Sendable]],
        tools: [[String: any Sendable]]?,
        additionalContext: [String: any Sendable]?
    ) throws -> [Int] {
        let parsed = try messages.map { message -> SemanticIfMessage in
            guard let role = message["role"] as? String, let content = message["content"] as? String,
                  let parsedRole = SemanticIfMessage.Role(rawValue: role)
            else { throw MLXLMCommon.TokenizerError.missingChatTemplate }
            return SemanticIfMessage(role: parsedRole, content: content)
        }
        return encode(text: try SemanticIfPrompt.applyQwen35ChatTemplate(parsed), addSpecialTokens: false)
    }
}

/// Renders the chat template to ids that do not match the pinned rendering:
/// the equivalence check in `SemanticIfTokenizer` must reject it.
struct MismatchedTemplateTokenizer: MLXLMCommon.Tokenizer {
    let upstream = FixtureTokenizer()

    func encode(text: String, addSpecialTokens: Bool) -> [Int] {
        upstream.encode(text: text, addSpecialTokens: addSpecialTokens)
    }

    func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String {
        upstream.decode(tokenIds: tokenIds, skipSpecialTokens: skipSpecialTokens)
    }

    func convertTokenToId(_ token: String) -> Int? { upstream.convertTokenToId(token) }
    func convertIdToToken(_ id: Int) -> String? { upstream.convertIdToToken(id) }
    var bosToken: String? { nil }
    var eosToken: String? { nil }
    var unknownToken: String? { nil }

    func applyChatTemplate(
        messages: [[String: any Sendable]],
        tools: [[String: any Sendable]]?,
        additionalContext: [String: any Sendable]?
    ) throws -> [Int] {
        try upstream.applyChatTemplate(messages: messages, tools: tools, additionalContext: additionalContext)
            + [0]
    }
}

/// The scorer never calls `prepare`, `newCache`, or the processor; only
/// `callAsFunction(_:cache:)` runs, once per decision, and the mock scripts
/// the last-position logits it returns.
final class FixtureLanguageModel: Module, LanguageModel, @unchecked Sendable {
    static let vocabSize = 128

    private let slotLogits: [Float]
    private let lock = NSLock()
    private var forwards = 0

    var forwardCount: Int {
        lock.withLock { forwards }
    }

    init(slotLogits: [Float]) {
        self.slotLogits = slotLogits
    }

    func callAsFunction(_ inputs: MLXArray, cache: [KVCache]?) -> MLXArray {
        lock.withLock { forwards += 1 }
        // [vocab] -> [1, 1, vocab]; `score` reads logits[0, -1].
        return MLXArray(slotLogits).reshaped([1, 1, slotLogits.count])
    }

    func prepare(_ input: LMInput, cache: [KVCache], windowSize: Int?) throws -> PrepareResult {
        .tokens(input.text)
    }

    func newCache(parameters: GenerateParameters?) -> [KVCache] { [] }
}

/// `score` never prepares user input; the context requires one regardless.
struct UnusedProcessor: UserInputProcessor {
    func prepare(input: UserInput) async throws -> LMInput {
        LMInput(tokens: MLXArray())
    }
}
