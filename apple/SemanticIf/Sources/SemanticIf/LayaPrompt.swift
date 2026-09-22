import Foundation

/// Native port of laya-coreml/common.py at 4619e0483f07adf39068532e85b42ec2347edb83.
/// See apple/ThirdParty/laya-coreml/NOTICE and LICENSE for attribution.
/// Only `choice` is needed by the warm-up classifier.
enum LayaPrompt {
    static let version = "laya-coreml-choice-v1"

    struct Tokens: Sendable {
        let cls: Int
        let sep: Int
        let pad: Int
        let mask: Int
        let maskText: String
    }

    struct Input: Sendable, Equatable {
        let ids: [Int]
        let markers: [Int]
        let paddedLength: Int
        let hash: String
    }

    static func prepare(_ row: SemanticIfRow, tokens: Tokens, maxLength: Int,
                        headMaxLength: Int, lengths: [Int], maxOptions: Int,
                        encode: (String) -> [Int]) throws -> Input {
        try SemanticIfPrompt.validate(row.decision)
        guard row.options.count <= maxOptions, row.options.allSatisfy({ !$0.id.isEmpty }),
              headMaxLength >= 16, maxLength > headMaxLength else {
            throw LayaCoreMLError.invalidConfiguration("Invalid option count or token budget.")
        }
        func clean(_ text: String) -> String { text.replacingOccurrences(of: tokens.maskText, with: " ") }
        var head = encode("choice question: " + clean(row.question))
        var options = row.options.map { option in
            let text = option.description.isEmpty ? option.id : option.id + ": " + option.description
            return [tokens.mask] + encode(" " + clean(text)).prefix(48)
        }
        var headBudget = headMaxLength - options.reduce(0) { $0 + $1.count }
        if headBudget < 16 {
            let perOption = max(4, (headMaxLength - 16) / options.count)
            options = options.map { Array($0.prefix(perOption)) }
            headBudget = headMaxLength - options.reduce(0) { $0 + $1.count }
        }
        head = Array(head.prefix(max(8, headBudget)))
        var ids = [tokens.cls] + head + [tokens.sep]
        var markers: [Int] = []
        for option in options {
            markers.append(ids.count)
            ids += option
        }
        ids.append(tokens.sep)
        let state: String
        if case .string(let text) = row.state { state = text } else { state = row.state.pythonDumped }
        let evidence = encode(clean(state))
        // Unlike upstream's generic helper, never silently discard OCR evidence.
        // The existing caller handles this error by consulting the screenshot planner.
        let count = ids.count + evidence.count + 1
        guard count <= maxLength, let padded = lengths.first(where: { $0 >= count }) else {
            throw LayaCoreMLError.inputTooLong(count, maxLength)
        }
        ids += evidence + [tokens.sep]
        let signature = version + "\n" + ids.map(String.init).joined(separator: ",")
            + "\n" + markers.map(String.init).joined(separator: ",")
        return Input(ids: ids, markers: markers, paddedLength: padded,
                     hash: SemanticIfPrompt.digest(signature))
    }

    /// The checkpoint's per-question/per-option temperature, clamped like
    /// laya-coreml 0.1.1 to prevent pathological confidence sharpening.
    static func temperature(count: Int, defaults: [Float], buckets: [String: Float]) throws -> Float {
        guard defaults.count == 3,
              (defaults + Array(buckets.values)).allSatisfy({ $0.isFinite && $0 > 0 }) else {
            throw LayaCoreMLError.invalidConfiguration("Calibration temperatures must be finite and positive.")
        }
        let bucket = count <= 2 ? "2" : count <= 5 ? "3-5" : count <= 10 ? "6-10" : "11+"
        return min(5, max(0.5, buckets["choice:" + bucket] ?? defaults[0]))
    }

    static func probabilities(logits: [Float], temperature: Float) throws -> [Double] {
        guard logits.count >= 2, logits.allSatisfy(\.isFinite), temperature.isFinite, temperature > 0 else {
            throw LayaCoreMLError.invalidOutput
        }
        let scaled = logits.map { $0 / temperature }
        guard scaled.allSatisfy(\.isFinite), let maximum = scaled.max() else { throw LayaCoreMLError.invalidOutput }
        let weights = scaled.map { exp($0 - maximum) }
        let total = weights.reduce(0, +)
        return weights.map { Double($0 / total) }
    }
}

enum LayaCoreMLError: LocalizedError, Equatable {
    case invalidConfiguration(String)
    case inputTooLong(Int, Int)
    case invalidOutput
    case damagedAsset(String)

    var errorDescription: String? {
        switch self {
        case .invalidConfiguration(let reason): "Laya Core ML: \(reason)"
        case .inputTooLong(let count, let limit): "Laya input has \(count) tokens; this model supports \(limit)."
        case .invalidOutput: "Laya Core ML returned invalid classification scores."
        case .damagedAsset(let name): "Laya model file is missing or damaged: \(name). Download the pinned model again."
        }
    }
}
