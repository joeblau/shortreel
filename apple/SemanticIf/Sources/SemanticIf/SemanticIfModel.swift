import Foundation
import Hub
import MLX
import MLXLLM
import MLXLMCommon
import OSLog
import Tokenizers

private let log = Logger(subsystem: "com.joeblau.shortreel", category: "SemanticIfModel")

/// Semif's direct categorical decision readout (`src/semif_phase1/direct.py`,
/// TheoLeeCJ/SemIf, MIT license) on MLX: one loaded model per process, one
/// forward pass per decision, last-position logits gathered onto the declared
/// answer slots, softmax in Float32. There is no sampler, no `TokenIterator`,
/// and no generated token.
///
/// All `MLXArray` values (non-`Sendable`) are created, evaluated, and consumed
/// inside `ModelContainer.perform` closures, so they never cross an isolation
/// boundary under Swift 6 strict concurrency. Public so the parity harness
/// (issue #13) can load the pinned checkpoint from its own module.
public actor SemanticIfModel {
    /// Semif's pinned checkpoint (Semif `models.json` / `--model`).
    public static let modelID = "Qwen/Qwen3.5-4B"
    public static let checkpointRevision = "851bf6e806efd8d0a36b00ddf55e13ccb7b8cd0a"

    /// Semif's default `--mlx-cache-limit-mib`: cap MLX's inactive buffer cache
    /// so it does not hold RAM while UI-TARS's Qwen2.5-VL is also resident.
    public static let gpuCacheLimitBytes = 256 * 1024 * 1024

    private let container: ModelContainer
    private let tokenizer: SemanticIfTokenizer

    /// Loads the pinned checkpoint, downloading it via `HubApi` when missing.
    ///
    /// - Parameter downloadBase: snapshot output root passed to `HubApi`.
    ///   Defaults to `~/Library/Application Support/ShortReel/huggingface`.
    public init(downloadBase: URL? = nil) async throws {
        Memory.cacheLimit = Self.gpuCacheLimitBytes
        let base = downloadBase ?? Self.defaultDownloadBase()
        let hub = HubApi(downloadBase: base)
        let container = try await LLMModelFactory.shared.loadContainer(
            from: SemanticIfDownloader(hub: hub),
            using: SemanticIfTokenizerLoader(),
            configuration: ModelConfiguration(id: Self.modelID, revision: Self.checkpointRevision)
        ) { progress in
            log.debug("checkpoint download: \(progress.fractionCompleted, privacy: .public)")
        }
        self.container = container
        self.tokenizer = SemanticIfTokenizer(tokenizer: await container.tokenizer)
        log.info(
            "loaded \(Self.modelID, privacy: .public) @ \(Self.checkpointRevision, privacy: .public); peak MLX memory \(Memory.peakMemory / (1024 * 1024), privacy: .public) MiB")
    }

    /// Test seam (issue #12): wraps an already-loaded container instead of
    /// downloading the pinned checkpoint. Used by the SPM tests in
    /// `apple/SemanticIf/Tests` with a mocked `LanguageModel`.
    init(container: ModelContainer, tokenizer: SemanticIfTokenizer) {
        self.container = container
        self.tokenizer = tokenizer
    }

    public static func defaultDownloadBase() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appending(path: "ShortReel", directoryHint: .isDirectory)
            .appending(path: "huggingface", directoryHint: .isDirectory)
    }

    /// `score` in direct.py: encode, one forward pass, gather slot logits,
    /// softmax in Float32. Any prompt-contract violation throws; nothing is
    /// ever approximated.
    public func score(_ row: SemanticIfDecision, maxTokens: Int = 4096) async throws -> SemanticIfScore {
        let started = ContinuousClock.now
        let encoded = try SemanticIfPrompt.encodePrompt(row, tokenizer: tokenizer, maxTokens: maxTokens)
        let forward = await container.perform(values: encoded) { context, encoded in
            let forwardStarted = ContinuousClock.now
            let logits = context.model(MLXArray(encoded.ids)[.newAxis], cache: nil)
            let last = logits[0, -1].asType(.float32)
            let gathered = last.take(MLXArray(encoded.answerSlots), axis: 0)
            // Blocks until the GPU finishes, so the clock covers the real pass.
            gathered.eval()
            let components = forwardStarted.duration(to: .now).components
            let forwardSeconds = Double(components.seconds) + Double(components.attoseconds) / 1e18
            return (slotLogits: gathered.asArray(Float.self), forwardSeconds: forwardSeconds)
        }
        let probabilities = try Self.softmax(forward.slotLogits)
        let ranked = probabilities.enumerated().sorted { $0.element > $1.element }
        let argmax = ranked[0].offset
        let margin = ranked[0].element - ranked[1].element
        let score = SemanticIfScore(
            rowID: row.id,
            probabilities: Dictionary(
                uniqueKeysWithValues: zip(row.options.map(\.id), probabilities.map(Double.init))),
            argmaxOptionID: row.options[argmax].id,
            margin: Double(margin),
            optionLogits: forward.slotLogits,
            inputTokens: encoded.ids.count,
            forwardSeconds: forward.forwardSeconds,
            totalSeconds: Self.seconds(since: started),
            promptHash: encoded.promptHash,
            peakMemoryBytes: Memory.peakMemory
        )
        log.info(
            "row \(row.id, privacy: .public): \(score.inputTokens) tokens, forward \(score.forwardSeconds, privacy: .public) s, total \(score.totalSeconds, privacy: .public) s, peak MLX memory \(score.peakMemoryBytes / (1024 * 1024), privacy: .public) MiB")
        return score
    }

    private static func seconds(since start: ContinuousClock.Instant) -> Double {
        let components = start.duration(to: .now).components
        return Double(components.seconds) + Double(components.attoseconds) / 1e18
    }

    /// `softmax` in core.py: rejects unless every score is finite, subtracts
    /// the max, exponentiates, normalizes — computed in Float32 per the issue
    /// contract (Semif computes in Python doubles).
    private static func softmax(_ values: [Float]) throws -> [Float] {
        guard values.count >= 2, values.allSatisfy(\.isFinite) else {
            throw SemanticIfModelError.nonFiniteScores
        }
        let maximum = values.max() ?? 0
        let weights = values.map { exp($0 - maximum) }
        let total = weights.reduce(0, +)
        return weights.map { $0 / total }
    }
}

/// One scored decision, mirroring the fields direct.py's `score` returns.
public struct SemanticIfScore: Sendable, Equatable {
    public var rowID: String
    /// Probability of each option id, in the row's declared option order.
    public var probabilities: [String: Double]
    public var argmaxOptionID: String
    /// Top probability minus runner-up probability.
    public var margin: Double
    public var optionLogits: [Float]
    public var inputTokens: Int
    public var forwardSeconds: Double
    public var totalSeconds: Double
    public var promptHash: String
    public var promptVersion = SemanticIfPrompt.promptVersion
    public var peakMemoryBytes: Int
}

enum SemanticIfModelError: Error, Equatable {
    case nonFiniteScores
    case chatTemplateMismatch
}

/// `SemanticIfTokenizing` over the swift-transformers tokenizer bundled with
/// mlx-swift-lm (exposed through `MLXLMCommon.Tokenizer`). `encode` is
/// `encode(_, addSpecialTokens: false)` and `applyDirectChatTemplate` is
/// `applyChatTemplate` with `addGenerationPrompt: true` and
/// `enable_thinking: false`, exactly as Semif calls them.
///
/// swift-transformers renders chat templates to token ids only, so the string
/// contract is served by `SemanticIfPrompt.applyQwen35ChatTemplate` (the
/// byte-exact pinned reference) and every call is proven equivalent by
/// requiring the template's token ids to equal the encoding of the reference
/// rendering. A mismatch throws; nothing is approximated.
struct SemanticIfTokenizer: SemanticIfTokenizing {
    let tokenizer: any MLXLMCommon.Tokenizer

    func encode(_ text: String) -> [Int32] {
        tokenizer.encode(text: text, addSpecialTokens: false).map { Int32($0) }
    }

    func decode(_ tokens: [Int32]) -> String {
        tokenizer.decode(tokenIds: tokens.map(Int.init), skipSpecialTokens: false)
    }

    func applyDirectChatTemplate(_ messages: [SemanticIfMessage]) throws -> String {
        let rendered = try SemanticIfPrompt.applyQwen35ChatTemplate(messages)
        let dicts = messages.map { ["role": $0.role.rawValue, "content": $0.content] as [String: any Sendable] }
        let templatedIDs = try tokenizer.applyChatTemplate(
            messages: dicts, tools: nil, additionalContext: ["enable_thinking": false])
        guard templatedIDs == tokenizer.encode(text: rendered, addSpecialTokens: false) else {
            throw SemanticIfModelError.chatTemplateMismatch
        }
        return rendered
    }
}

/// `MLXLMCommon.Downloader` over swift-transformers' `HubApi`, snapshotting
/// the pinned revision into `downloadBase` (Application Support by default).
private struct SemanticIfDownloader: MLXLMCommon.Downloader {
    let hub: HubApi

    func download(
        id: String,
        revision: String?,
        matching patterns: [String],
        useLatest: Bool,
        progressHandler: @Sendable @escaping (Progress) -> Void
    ) async throws -> URL {
        try await hub.snapshot(
            from: id,
            revision: revision ?? "main",
            matching: patterns,
            progressHandler: progressHandler
        )
    }
}

/// `MLXLMCommon.TokenizerLoader` over swift-transformers' `AutoTokenizer`,
/// bridging to `MLXLMCommon.Tokenizer` exactly as mlx-swift-lm's
/// `#huggingFaceTokenizerLoader()` macro does.
private struct SemanticIfTokenizerLoader: MLXLMCommon.TokenizerLoader {
    func load(from directory: URL) async throws -> any MLXLMCommon.Tokenizer {
        SemanticIfTokenizerBridge(upstream: try await AutoTokenizer.from(modelFolder: directory))
    }
}

private struct SemanticIfTokenizerBridge: MLXLMCommon.Tokenizer {
    let upstream: any Tokenizers.Tokenizer

    func encode(text: String, addSpecialTokens: Bool) -> [Int] {
        upstream.encode(text: text, addSpecialTokens: addSpecialTokens)
    }

    func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String {
        upstream.decode(tokens: tokenIds, skipSpecialTokens: skipSpecialTokens)
    }

    func convertTokenToId(_ token: String) -> Int? {
        upstream.convertTokenToId(token)
    }

    func convertIdToToken(_ id: Int) -> String? {
        upstream.convertIdToToken(id)
    }

    var bosToken: String? { upstream.bosToken }
    var eosToken: String? { upstream.eosToken }
    var unknownToken: String? { upstream.unknownToken }

    func applyChatTemplate(
        messages: [[String: any Sendable]],
        tools: [[String: any Sendable]]?,
        additionalContext: [String: any Sendable]?
    ) throws -> [Int] {
        do {
            return try upstream.applyChatTemplate(
                messages: messages, tools: tools, additionalContext: additionalContext)
        } catch Tokenizers.TokenizerError.missingChatTemplate {
            throw MLXLMCommon.TokenizerError.missingChatTemplate
        }
    }
}
