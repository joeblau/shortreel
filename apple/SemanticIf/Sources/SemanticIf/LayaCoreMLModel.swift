import CoreML
import CryptoKit
import Foundation
import Hub
import Tokenizers

/// Laya's released multilingual Core ML model, with native Swift tokenization,
/// input construction and calibrated choice readout. No Python runtime is used.
public actor LayaCoreMLModel: SemanticIfScoring {
    public static let modelID = "aac6fef/laya-multilingual-coreml"
    public static let checkpointRevision = "8139e9089273319512c730218903784074133187"
    private static let manifestHash = "8131967fdb403243f2817d7eeb09721d1e822bd7301c244d25afb44bcc258352"

    private let model: MLModel
    private let tokenizer: any Tokenizers.Tokenizer
    private let tokens: LayaPrompt.Tokens
    private let manifest: Manifest
    private let agent: AgentConfiguration

    /// An explicit directory supports offline installations and integration tests.
    /// Otherwise the pinned bundle downloads once into Application Support.
    public init(modelDirectory: URL? = nil) async throws {
        try Task.checkCancellation()
        let directory: URL
        var cachedManifest: Manifest?
        if let modelDirectory {
            directory = modelDirectory
        } else if let override = ProcessInfo.processInfo.environment["SHORTREEL_LAYA_MODEL_DIR"], !override.isEmpty {
            directory = URL(fileURLWithPath: override)
        } else {
            let hub = HubApi(downloadBase: Self.defaultDownloadBase())
            let cached = hub.localRepoLocation(HubApi.Repo(id: Self.modelID))
            do { cachedManifest = try Self.validateBundle(cached) }
            catch is CancellationError { throw CancellationError() }
            catch { cachedManifest = nil }
            if cachedManifest != nil {
                directory = cached
            } else {
                directory = try await hub.snapshot(from: Self.modelID, revision: Self.checkpointRevision)
            }
        }
        try Task.checkCancellation()
        manifest = try cachedManifest ?? Self.validateBundle(directory)
        agent = try JSONDecoder().decode(AgentConfiguration.self,
            from: Data(contentsOf: directory.appending(path: "rl_agent_config.json")))
        guard agent.max_len == manifest.shape.max_length,
              agent.head_max_len >= 16, agent.head_max_len < agent.max_len else {
            throw LayaCoreMLError.invalidConfiguration("Unsupported Laya token budgets.")
        }
        _ = try LayaPrompt.temperature(count: 2, defaults: agent.temperature, buckets: agent.temperature_by_options)
        let tokenizerDirectory = directory.appending(path: "tokenizer")
        let tokenizer = try await AutoTokenizer.from(modelFolder: tokenizerDirectory)
        self.tokenizer = tokenizer
        tokens = try Self.specialTokens(in: tokenizerDirectory, tokenizer: tokenizer)
        try Task.checkCancellation()
        let compiled = directory.appending(path: "shortreel-model.mlmodelc")
        if !FileManager.default.fileExists(atPath: compiled.path) {
            let temporary = try await MLModel.compileModel(at: directory.appending(path: "model.mlpackage"))
            defer { try? FileManager.default.removeItem(at: temporary) }
            try Task.checkCancellation()
            do { try FileManager.default.moveItem(at: temporary, to: compiled) }
            catch {
                // A simultaneous load can finish the same immutable bundle first.
                guard FileManager.default.fileExists(atPath: compiled.path) else { throw error }
            }
        }
        let configuration = MLModelConfiguration()
        // This general-purpose export is validated on CPU + GPU. Merely selecting
        // Neural Engine here does not turn it into upstream's separate ANE graph.
        configuration.computeUnits = .cpuAndGPU
        model = try MLModel(contentsOf: compiled, configuration: configuration)
    }

    private static func specialTokens(in directory: URL, tokenizer: any Tokenizers.Tokenizer) throws -> LayaPrompt.Tokens {
        let config = try JSONSerialization.jsonObject(with:
            Data(contentsOf: directory.appending(path: "tokenizer_config.json"))) as? [String: Any]
        func special(_ key: String) throws -> (String, Int) {
            guard let text = config?[key] as? String, let id = tokenizer.convertTokenToId(text) else {
                throw LayaCoreMLError.invalidConfiguration("Missing tokenizer token: \(key).")
            }
            return (text, id)
        }
        return try LayaPrompt.Tokens(cls: special("cls_token").1, sep: special("sep_token").1,
            pad: special("pad_token").1, mask: special("mask_token").1, maskText: special("mask_token").0)
    }

    public static func defaultDownloadBase() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "ShortReel/laya-coreml/" + checkpointRevision, directoryHint: .isDirectory)
    }

    func prepare(_ row: SemanticIfRow) throws -> LayaPrompt.Input {
        try LayaPrompt.prepare(row, tokens: tokens, maxLength: agent.max_len,
            headMaxLength: agent.head_max_len, lengths: manifest.shape.lengths,
            maxOptions: manifest.shape.max_options,
            encode: { tokenizer.encode(text: $0, addSpecialTokens: false) })
    }

    public func score(_ row: SemanticIfRow) async throws -> SemanticIfResult {
        try Task.checkCancellation()
        let started = ContinuousClock.now
        let input = try prepare(row)
        let batch = try Self.batch(input, pad: tokens.pad, maxOptions: manifest.shape.max_options)
        let forwardStarted = ContinuousClock.now
        // The actor serializes predictions; MLModel and MLMultiArray stay inside it.
        let output = try predict(batch)
        try Task.checkCancellation()
        let forwardSeconds = Self.seconds(since: forwardStarted)
        guard let logits = output.featureValue(for: "logits")?.multiArrayValue,
              logits.shape.map(\.intValue) == [1, manifest.shape.max_options],
              let actions = output.featureValue(for: "action_logits")?.multiArrayValue,
              actions.count == 2,
              (0..<actions.count).allSatisfy({ actions[$0].floatValue.isFinite }),
              (0..<logits.count).allSatisfy({ logits[$0].floatValue.isFinite }) else {
            throw LayaCoreMLError.invalidOutput
        }
        let values = row.options.indices.map { logits[[0, NSNumber(value: $0)]].floatValue }
        let temperature = try LayaPrompt.temperature(count: values.count,
            defaults: agent.temperature, buckets: agent.temperature_by_options)
        let probabilities = try LayaPrompt.probabilities(logits: values, temperature: temperature)
        // Resolve ties in declaration order, matching numpy.argmax.
        let ranked = probabilities.indices.sorted {
            probabilities[$0] == probabilities[$1] ? $0 < $1 : probabilities[$0] > probabilities[$1]
        }
        let best = ranked[0]
        let score = SemanticIfScore(rowID: row.id,
            probabilities: Dictionary(uniqueKeysWithValues: zip(row.options.map(\.id), probabilities)),
            argmaxOptionID: row.options[best].id,
            margin: probabilities[best] - probabilities[ranked[1]], optionLogits: values,
            inputTokens: input.ids.count, forwardSeconds: forwardSeconds,
            totalSeconds: Self.seconds(since: started),
            promptHash: SemanticIfPrompt.digest(Self.checkpointRevision + "\n" + input.hash),
            promptVersion: LayaPrompt.version, peakMemoryBytes: 0)
        return SemanticIfResult(score: score)
    }

    static func batch(_ input: LayaPrompt.Input, pad: Int, maxOptions: Int) throws -> MLDictionaryFeatureProvider {
        func array(_ values: [Int], count: Int, fill: Int = 0) throws -> MLMultiArray {
            let array = try MLMultiArray(shape: [1, NSNumber(value: count)], dataType: .int32)
            for i in 0..<count { array[i] = NSNumber(value: i < values.count ? values[i] : fill) }
            return array
        }
        let qtype = try MLMultiArray(shape: [1], dataType: .int32)
        qtype[0] = 0  // choice
        return try MLDictionaryFeatureProvider(dictionary: [
            "input_ids": array(input.ids, count: input.paddedLength, fill: pad),
            "attention_mask": array(Array(repeating: 1, count: input.ids.count), count: input.paddedLength),
            "marker_pos": array(input.markers, count: maxOptions),
            "marker_mask": array(Array(repeating: 1, count: input.markers.count), count: maxOptions),
            "qtype": qtype,
        ])
    }

    private func predict(_ input: MLDictionaryFeatureProvider) throws -> any MLFeatureProvider {
        try model.prediction(from: input)
    }

    private static func seconds(since start: ContinuousClock.Instant) -> Double {
        let c = start.duration(to: .now).components
        return Double(c.seconds) + Double(c.attoseconds) / 1e18
    }

    private struct Manifest: Decodable, Sendable {
        struct Shape: Decodable, Sendable {
            let batch_size: Int
            let max_length: Int
            let max_options: Int
            let lengths: [Int]
        }
        struct File: Decodable, Sendable { let bytes: Int; let sha256: String }
        let format: String
        let format_version: Int
        let shape: Shape
        let files: [String: File]
    }

    private struct AgentConfiguration: Decodable, Sendable {
        let max_len: Int
        let head_max_len: Int
        let temperature: [Float]
        let temperature_by_options: [String: Float]
    }

    /// Pin the release and stream-check every asset, including the weights.
    /// This also detects incomplete downloads before loading cached compiled code.
    private static func validateBundle(_ directory: URL) throws -> Manifest {
        let manifestURL = directory.appending(path: "coreml_config.json")
        guard try digestFile(manifestURL) == manifestHash else {
            throw LayaCoreMLError.damagedAsset("coreml_config.json")
        }
        let manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: manifestURL))
        guard manifest.format == "laya-coreml", manifest.format_version == 1,
              manifest.shape.batch_size == 1, manifest.shape.max_length == 1024,
              manifest.shape.max_options == 32,
              manifest.shape.lengths == manifest.shape.lengths.sorted(),
              manifest.shape.lengths.first ?? 0 > 0,
              manifest.shape.lengths.last == manifest.shape.max_length else {
            throw LayaCoreMLError.invalidConfiguration("Unsupported Core ML export shape.")
        }
        for (name, file) in manifest.files {
            try Task.checkCancellation()
            let url = directory.appending(path: name)
            let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize
            guard size == file.bytes, try digestFile(url) == file.sha256 else {
                throw LayaCoreMLError.damagedAsset(name)
            }
        }
        return manifest
    }

    private static func digestFile(_ url: URL) throws -> String {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        var hash = SHA256()
        while let data = try file.read(upToCount: 1024 * 1024), !data.isEmpty {
            try Task.checkCancellation()
            hash.update(data: data)
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

extension SemanticIfScorerBackend {
    public func makeScorer() async throws -> any SemanticIfScoring {
        switch self {
        case .layaCoreML: try await LayaCoreMLModel()
        }
    }
}
