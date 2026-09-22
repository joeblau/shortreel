// cd apple/SemanticIf && swift test
//
// Shared-mode tests (issue #17): prefill the shared state once, forward each
// criterion as a batch-1 suffix on a copy of the cache. The mocked tests run
// without the checkpoint and pin the state/suffix split and the
// shared-equals-direct contract against a scripted `LanguageModel`; the
// pinned-checkpoint test at the bottom is opt-in (SEMIF_MODEL_DIR) and is the
// cache-correctness gate of Semif's docs/MLX.md "Cache correctness" section:
// shared results must equal direct results for the same rows within the parity
// tolerance.

import CryptoKit
import Foundation
import MLX
import MLXLMCommon
import MLXNN
import XCTest

import SemanticIfParity
@testable import SemanticIf

final class SemanticIfSharedModeTests: XCTestCase {
    static let fixturesURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // SemanticIfTests/
        .deletingLastPathComponent()  // Tests/
        .deletingLastPathComponent()  // package root
        .appending(path: "Fixtures", directoryHint: .isDirectory)

    /// The multi-criterion fixture: four criteria over one exact shared state
    /// (the support-1 state from decisions.jsonl).
    static func sharedFixtureRows() throws -> [SemanticIfDecision] {
        try String(contentsOf: fixturesURL.appending(path: "shared-decisions.jsonl"), encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { try SemanticIfDecision(json: SemanticIfJSON.parse(String($0))) }
    }

    static func makeModel(
        slotLogits: [Float]
    ) -> (SemanticIfModel, RecordingLanguageModel) {
        let model = RecordingLanguageModel(slotLogits: slotLogits)
        let tokenizer = FixtureTokenizer()
        let container = ModelContainer(
            context: ModelContext(
                configuration: ModelConfiguration(id: "semif-fixture"),
                model: model,
                processor: UnusedProcessor(),
                tokenizer: tokenizer))
        return (SemanticIfModel(container: container, tokenizer: SemanticIfTokenizer(tokenizer: tokenizer)), model)
    }

    static func scriptedLogits() -> [Float] {
        var logits = [Float](repeating: -10, count: RecordingLanguageModel.vocabSize)
        logits[65] = 1   // A
        logits[66] = 3   // B
        logits[67] = 2   // C
        return logits
    }

    // MARK: - fixture integrity (no checkpoint needed)

    /// The fixture's SHA-256 equals the sum pinned in Fixtures/SHA256SUMS.
    func testSharedFixtureHashMatchesPin() throws {
        let data = try Data(contentsOf: Self.fixturesURL.appending(path: "shared-decisions.jsonl"))
        let actual = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let pins = try String(contentsOf: Self.fixturesURL.appending(path: "SHA256SUMS"), encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map(String.init)
        let pin = try XCTUnwrap(pins.first(where: { $0.hasSuffix("  shared-decisions.jsonl") }))
        XCTAssertEqual(String(pin.prefix(64)), actual)
    }

    /// The fixture rows share one exact state and carry unique ids — Semif's
    /// shared-mode input contract.
    func testSharedFixtureShape() throws {
        let rows = try Self.sharedFixtureRows()
        XCTAssertEqual(rows.map(\.id), ["shared-success", "shared-rollback", "shared-health", "shared-time"])
        XCTAssertEqual(Set(rows.map(\.id)).count, rows.count)
        for row in rows.dropFirst() {
            XCTAssertEqual(row.state, rows[0].state)
        }
    }

    // MARK: - the state/suffix split (mocked tokenizer)

    /// `_state_prefix`: the prefix is nonempty, is an exact token prefix of
    /// every full prompt, leaves a nonempty suffix, and is identical for every
    /// row sharing the state.
    func testStatePrefixSplitsEverySharedRowExactly() throws {
        let tokenizer = SemanticIfTokenizer(tokenizer: FixtureTokenizer())
        let rows = try Self.sharedFixtureRows()
        let prefix = try SemanticIfPrompt.statePrefixIDs(state: rows[0].state, tokenizer: tokenizer)
        XCTAssertFalse(prefix.isEmpty)
        for row in rows {
            let full = try SemanticIfPrompt.encodePrompt(row, tokenizer: tokenizer)
            XCTAssertGreaterThan(full.ids.count, prefix.count, row.id)
            XCTAssertTrue(full.ids.starts(with: prefix), row.id)
            let rowPrefix = try SemanticIfPrompt.statePrefixIDs(state: row.state, tokenizer: tokenizer)
            XCTAssertEqual(rowPrefix, prefix, row.id)
        }
        // The boundary sits inside the evidence payload: two rows whose states
        // differ must get different prefixes.
        let other = try SemanticIfPrompt.encodePrompt(
            SemanticIfModelTests.sampleRow(), tokenizer: tokenizer)
        XCTAssertFalse(other.ids.starts(with: prefix))
    }

    // MARK: - shared == direct (mocked model)

    /// Against the scripted model, scoreShared returns exactly what direct
    /// `score` returns for every row (logits, probabilities, argmax, hash,
    /// token count) and issues exactly one prefill plus one suffix forward per
    /// row — versus one full forward per row in direct mode. The recorded
    /// forwards prove prefix + suffix reconstructs each full prompt exactly.
    func testSharedMatchesDirectOnMock() async throws {
        let rows = try Self.sharedFixtureRows()

        let (directModel, directFixture) = Self.makeModel(slotLogits: Self.scriptedLogits())
        var directScores: [SemanticIfScore] = []
        for row in rows {
            directScores.append(try await directModel.score(row))
        }
        XCTAssertEqual(directFixture.forwardedInputs.count, rows.count)

        let (sharedModel, sharedFixture) = Self.makeModel(slotLogits: Self.scriptedLogits())
        let result = try await sharedModel.scoreShared(rows)

        XCTAssertEqual(result.scores.count, rows.count)
        XCTAssertEqual(sharedFixture.forwardedInputs.count, 1 + rows.count)
        for (index, row) in rows.enumerated() {
            let direct = directScores[index]
            let shared = result.scores[index]
            XCTAssertEqual(shared.rowID, row.id)
            XCTAssertEqual(shared.optionLogits, direct.optionLogits, row.id)
            XCTAssertEqual(shared.probabilities, direct.probabilities, row.id)
            XCTAssertEqual(shared.argmaxOptionID, direct.argmaxOptionID, row.id)
            XCTAssertEqual(shared.promptHash, direct.promptHash, row.id)
            XCTAssertEqual(shared.inputTokens, direct.inputTokens, row.id)
            // Direct forwarded the full prompt; shared forwarded the shared
            // prefix once and then exactly the remaining suffix for this row.
            let full = directFixture.forwardedInputs[index]
            let prefix = sharedFixture.forwardedInputs[0]
            let suffix = sharedFixture.forwardedInputs[1 + index]
            XCTAssertEqual(prefix + suffix, full, row.id)
            XCTAssertFalse(suffix.isEmpty, row.id)
        }
        XCTAssertEqual(result.prefixTokens, sharedFixture.forwardedInputs[0].count)
        XCTAssertEqual(
            result.suffixTokens,
            sharedFixture.forwardedInputs.dropFirst().map(\.count).reduce(0, +))
        XCTAssertEqual(result.suffixForwardSeconds, result.scores.map(\.forwardSeconds).reduce(0, +))
    }

    // MARK: - validation (no forward pass on rejection)

    /// Semif raises unless every row carries the exact same state; the batch
    /// is rejected before any forward pass.
    func testSharedRejectsMismatchedStates() async throws {
        var rows = try Self.sharedFixtureRows()
        rows[1].state = .string("A different state.")
        let (model, fixture) = Self.makeModel(slotLogits: Self.scriptedLogits())
        do {
            _ = try await model.scoreShared(rows)
            XCTFail("Mismatched states must reject the batch")
        } catch let error as SemanticIfSharedError {
            XCTAssertEqual(error, .sharedStateMismatch)
        }
        XCTAssertEqual(fixture.forwardedInputs.count, 0)
    }

    /// Semif requires unique decision ids and a nonempty batch.
    func testSharedRejectsDuplicateIDsAndEmptyBatch() async throws {
        var rows = try Self.sharedFixtureRows()
        rows[1].id = rows[0].id
        let (model, fixture) = Self.makeModel(slotLogits: Self.scriptedLogits())
        do {
            _ = try await model.scoreShared(rows)
            XCTFail("Duplicate ids must reject the batch")
        } catch let error as SemanticIfSharedError {
            XCTAssertEqual(error, .duplicateDecisionIDs)
        }
        do {
            _ = try await model.scoreShared([])
            XCTFail("An empty batch must be rejected")
        } catch let error as SemanticIfSharedError {
            XCTAssertEqual(error, .noRows)
        }
        XCTAssertEqual(fixture.forwardedInputs.count, 0)
    }

    // MARK: - opt-in pinned checkpoint: the cache-correctness gate

    /// The issue #17 acceptance gate: on the pinned Qwen3.5-4B checkpoint,
    /// shared mode must equal direct mode for the same rows — argmax 100 % and
    /// max |Δp| within the parity harness tolerance (0.12). Row
    /// `shared-success` repeats decisions.jsonl's `support-1` verbatim, so its
    /// shared-mode result is additionally compared against Semif's published
    /// BF16 direct-mode row. The prefill-once vs N-full-forwards speedup is
    /// measured and printed (archived in Fixtures/SHARED.md).
    func testSharedMatchesDirectOnPinnedCheckpoint() async throws {
        let base = ProcessInfo.processInfo.environment["SEMIF_MODEL_DIR"].map(URL.init(fileURLWithPath:))
            ?? SemanticIfModel.defaultDownloadBase()
        let snapshot = base.appending(path: "models/Qwen/Qwen3.5-4B")
        guard FileManager.default.fileExists(atPath: snapshot.appending(path: "config.json").path) else {
            throw XCTSkip("pinned checkpoint not cached at \(snapshot.path); set SEMIF_MODEL_DIR to opt in")
        }
        let rows = try Self.sharedFixtureRows()
        let model = try await SemanticIfModel(downloadBase: base)

        // Direct mode: N full forwards, timed as a batch.
        let directStarted = ContinuousClock.now
        var directScores: [SemanticIfScore] = []
        for row in rows {
            directScores.append(try await model.score(row))
        }
        let directSeconds = Self.seconds(since: directStarted)

        // Shared mode: one prefill + one suffix forward per row.
        let sharedResult = try await model.scoreShared(rows)

        var maxDeltaP = 0.0
        var argmaxAgree = 0
        for (index, row) in rows.enumerated() {
            let direct = directScores[index]
            let shared = sharedResult.scores[index]
            XCTAssertEqual(shared.promptHash, direct.promptHash, row.id)
            XCTAssertEqual(shared.inputTokens, direct.inputTokens, row.id)
            let rowDelta = Self.maxDeltaP(shared: shared, direct: direct, row: row)
            maxDeltaP = max(maxDeltaP, rowDelta)
            if shared.argmaxOptionID == direct.argmaxOptionID { argmaxAgree += 1 }
            print(String(
                format: "shared-vs-direct %@: argmax %@/%@%@  max|Δp|=%.3e",
                row.id, shared.argmaxOptionID, direct.argmaxOptionID,
                shared.argmaxOptionID == direct.argmaxOptionID ? "" : " FLIP", rowDelta))
        }
        print(String(
            format: "shared-vs-direct summary: argmax %d/%d, max |Δp| %.6e (tolerance %.2f)",
            argmaxAgree, rows.count, maxDeltaP, SemifParity.tolerance))
        XCTAssertEqual(argmaxAgree, rows.count, "argmax agreement must be 100 %")
        XCTAssertLessThanOrEqual(maxDeltaP, SemifParity.tolerance)

        // Cross-check the verbatim support-1 criterion against Semif's
        // published BF16 direct-mode row for decisions.jsonl.
        let decisions = SemifParity.sets[0]
        let (_, recorded) = try SemifParity.load(decisions, fixturesDir: Self.fixturesURL)
        let reference = try XCTUnwrap(recorded["support-1"])
        let sharedSuccess = sharedResult.scores[0]
        XCTAssertEqual(sharedSuccess.promptHash, reference.promptSHA256)
        XCTAssertEqual(sharedSuccess.argmaxOptionID, reference.argmaxOptionID)
        var publishedDelta = 0.0
        for (index, optionID) in reference.optionIDs.enumerated() {
            publishedDelta = max(
                publishedDelta,
                abs((sharedSuccess.probabilities[optionID] ?? -1) - reference.probabilities[index]))
        }
        print(String(format: "shared(shared-success) vs Semif published direct(support-1): max |Δp| %.6e", publishedDelta))
        XCTAssertLessThanOrEqual(publishedDelta, SemifParity.tolerance)

        // Measured speedup for the multi-criterion case (reported, not gated).
        let speedup = directSeconds / sharedResult.totalSeconds
        print(String(
            format: """
                shared-mode timing (\(rows.count) criteria, \(sharedResult.prefixTokens) prefix tokens, \
                \(sharedResult.suffixTokens) suffix tokens):
                  direct:  %.3fs total (%d full forwards)
                  shared:  %.3fs total (encode %.3fs, prefill %.3fs once, replicate %.3fs, suffixes %.3fs)
                  speedup: %.2fx
                """,
            directSeconds, rows.count,
            sharedResult.totalSeconds, sharedResult.encodeSeconds, sharedResult.prefillSeconds,
            sharedResult.replicateSeconds, sharedResult.suffixForwardSeconds,
            speedup))

        // A larger batch — one long shared state against the same four
        // criteria — measures the prefill-once speedup at realistic state
        // sizes: the fixture's state is only ~65 prefix tokens, so per-call
        // overhead dominates there and the speedup is modest.
        let logLine = "2026-09-21T14:02:13Z [deploy] zone healthy; replicas=3; errors=0; latency_p99_ms=42\n"
        let longRows = rows.map { row in
            SemanticIfDecision(
                id: row.id + "-long", state: .string(String(repeating: logLine, count: 80)),
                question: row.question, options: row.options)
        }
        let longDirectStarted = ContinuousClock.now
        var longDirectScores: [SemanticIfScore] = []
        for row in longRows {
            longDirectScores.append(try await model.score(row))
        }
        let longDirectSeconds = Self.seconds(since: longDirectStarted)
        let longShared = try await model.scoreShared(longRows)
        var longMaxDeltaP = 0.0
        var longArgmaxAgree = 0
        for (index, row) in longRows.enumerated() {
            XCTAssertEqual(longShared.scores[index].promptHash, longDirectScores[index].promptHash, row.id)
            longMaxDeltaP = max(
                longMaxDeltaP, Self.maxDeltaP(shared: longShared.scores[index], direct: longDirectScores[index], row: row))
            if longShared.scores[index].argmaxOptionID == longDirectScores[index].argmaxOptionID {
                longArgmaxAgree += 1
            }
        }
        XCTAssertEqual(longArgmaxAgree, longRows.count, "long-state argmax agreement must be 100 %")
        XCTAssertLessThanOrEqual(longMaxDeltaP, SemifParity.tolerance)
        print(String(
            format: """
                long-state shared-mode timing (\(longRows.count) criteria, \(longShared.prefixTokens) prefix tokens, \
                \(longShared.suffixTokens) suffix tokens):
                  direct:  %.3fs total (%d full forwards)
                  shared:  %.3fs total (encode %.3fs, prefill %.3fs once, replicate %.3fs, suffixes %.3fs)
                  speedup: %.2fx; argmax %d/%d, max |Δp| %.6e
                """,
            longDirectSeconds, longRows.count,
            longShared.totalSeconds, longShared.encodeSeconds, longShared.prefillSeconds,
            longShared.replicateSeconds, longShared.suffixForwardSeconds,
            longDirectSeconds / longShared.totalSeconds, longArgmaxAgree, longRows.count, longMaxDeltaP))
    }

    private static func maxDeltaP(
        shared: SemanticIfScore, direct: SemanticIfScore, row: SemanticIfDecision
    ) -> Double {
        var delta = 0.0
        for option in row.options {
            delta = max(
                delta,
                abs((shared.probabilities[option.id] ?? -1) - (direct.probabilities[option.id] ?? -2)))
        }
        return delta
    }

    private static func seconds(since start: ContinuousClock.Instant) -> Double {
        let components = start.duration(to: .now).components
        return Double(components.seconds) + Double(components.attoseconds) / 1e18
    }
}

/// A scripted `LanguageModel` that records every forwarded token sequence so
/// the tests can prove the shared mode's prefill + suffix split reconstructs
/// each full prompt exactly. `newCache` returns no caches, as the #12 fixture
/// model does; the shared path only requires the array to be copyable.
final class RecordingLanguageModel: Module, LanguageModel, @unchecked Sendable {
    static let vocabSize = 128

    private let slotLogits: [Float]
    private let lock = NSLock()
    private var inputs: [[Int]] = []

    var forwardedInputs: [[Int]] {
        lock.withLock { inputs }
    }

    init(slotLogits: [Float]) {
        self.slotLogits = slotLogits
    }

    func callAsFunction(_ inputs: MLXArray, cache: [KVCache]?) -> MLXArray {
        lock.withLock { self.inputs.append(inputs.asArray(Int32.self).map(Int.init)) }
        // [vocab] -> [1, 1, vocab]; the readout reads logits[0, -1].
        return MLXArray(slotLogits).reshaped([1, 1, slotLogits.count])
    }

    func prepare(_ input: LMInput, cache: [KVCache], windowSize: Int?) throws -> PrepareResult {
        .tokens(input.text)
    }

    func newCache(parameters: GenerateParameters?) -> [KVCache] { [] }
}
