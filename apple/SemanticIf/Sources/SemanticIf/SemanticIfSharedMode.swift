import Foundation
import MLX
import MLXLMCommon
import OSLog

private let log = Logger(subsystem: "com.joeblau.shortreel", category: "SemanticIfSharedMode")

/// Semif's parallel-shared mode (`src/semif_phase1/shared.py`, TheoLeeCJ/SemIf,
/// MIT license) on MLX Swift: when several decision rows share one exact
/// state, the state prefix is prefilled into a KV cache once and each
/// criterion is forwarded as a short batch-1 suffix on a deep copy of that
/// cache (Semif's MPS path — "prefill once, then independent batch-1
/// suffixes"). The last-position logits, slot gather, and Float32 softmax are
/// identical to direct mode (`SemanticIfModel.score`), so shared results equal
/// direct results for the same rows up to GPU kernel shape effects; that
/// equivalence is the cache-correctness gate exercised by the #17 tests
/// (Semif `docs/MLX.md` "Cache correctness").
extension SemanticIfModel {
    /// Scores every row after a single prefill of their shared state.
    ///
    /// All rows must carry the exact same `state` (byte-equal JSON, as Semif
    /// requires) and unique ids. Each row is rendered through the same
    /// `SemanticIfPrompt.encodePrompt` path as direct mode; the shared prefix
    /// is everything through the evidence payload (`_state_prefix` in
    /// shared.py) and must be an exact token prefix of every full prompt, with
    /// a nonempty suffix per row. Any violation throws; nothing is
    /// approximated.
    ///
    /// - Returns: per-row scores in input order plus the prefill/replicate/
    ///   suffix timing breakdown Semif records (`timing` in shared.py).
    public func scoreShared(
        _ rows: [SemanticIfDecision],
        maxTokens: Int = 4096
    ) async throws -> SemanticIfSharedResult {
        let started = ContinuousClock.now
        guard let first = rows.first else { throw SemanticIfSharedError.noRows }
        for row in rows.dropFirst() where row.state != first.state {
            throw SemanticIfSharedError.sharedStateMismatch
        }
        guard Set(rows.map(\.id)).count == rows.count else {
            throw SemanticIfSharedError.duplicateDecisionIDs
        }
        let prefixIDs = try SemanticIfPrompt.statePrefixIDs(state: first.state, tokenizer: tokenizer)
        var encoded: [SemanticIfEncodedPrompt] = []
        var suffixes: [[Int32]] = []
        for row in rows {
            let full = try SemanticIfPrompt.encodePrompt(row, tokenizer: tokenizer, maxTokens: maxTokens)
            guard full.ids.count > prefixIDs.count, full.ids.starts(with: prefixIDs) else {
                throw SemanticIfSharedError.prefixMismatch(rowID: row.id)
            }
            encoded.append(full)
            suffixes.append(Array(full.ids[prefixIDs.count...]))
        }
        let encodeSeconds = Self.seconds(since: started)

        let input = SemanticIfSharedForwardInput(
            prefix: prefixIDs,
            suffixes: suffixes,
            answerSlots: encoded.map(\.answerSlots))
        let forward = await container.perform(values: input) { context, input in
            // One prefill of the shared state prefix into a fresh cache.
            let cache = context.model.newCache(parameters: nil)
            let prefillStarted = ContinuousClock.now
            let prefillLogits = context.model(MLXArray(input.prefix)[.newAxis], cache: cache)
            // Blocks until the GPU finishes; the cache state is part of the
            // same lazy graph, so this materializes the prefix K/V and
            // recurrent state before any branch copies it.
            prefillLogits[0, -1].eval()
            let prefillSeconds = SemanticIfModel.seconds(since: prefillStarted)

            var replicateSeconds = 0.0
            var suffixSeconds: [Double] = []
            var slotLogits: [[Float]] = []
            for (suffix, slots) in zip(input.suffixes, input.answerSlots) {
                let copyStarted = ContinuousClock.now
                let branch = cache.map { $0.copy() }
                replicateSeconds += SemanticIfModel.seconds(since: copyStarted)
                let suffixStarted = ContinuousClock.now
                let logits = context.model(MLXArray(suffix)[.newAxis], cache: branch)
                let last = logits[0, -1].asType(.float32)
                let gathered = last.take(MLXArray(slots), axis: 0)
                // Same blocking readout as direct mode: the clock covers the
                // real pass and the values are safe to return.
                gathered.eval()
                suffixSeconds.append(SemanticIfModel.seconds(since: suffixStarted))
                slotLogits.append(gathered.asArray(Float.self))
            }
            return (
                slotLogits: slotLogits, prefillSeconds: prefillSeconds,
                replicateSeconds: replicateSeconds, suffixSeconds: suffixSeconds
            )
        }

        var scores: [SemanticIfScore] = []
        for (index, row) in rows.enumerated() {
            let probabilities = try Self.softmax(forward.slotLogits[index])
            let ranked = probabilities.enumerated().sorted { $0.element > $1.element }
            let argmax = ranked[0].offset
            let margin = ranked[0].element - ranked[1].element
            scores.append(SemanticIfScore(
                rowID: row.id,
                probabilities: Dictionary(
                    uniqueKeysWithValues: zip(row.options.map(\.id), probabilities.map(Double.init))),
                argmaxOptionID: row.options[argmax].id,
                margin: Double(margin),
                optionLogits: forward.slotLogits[index],
                inputTokens: encoded[index].ids.count,
                // The row's own forward is just its suffix; `totalSeconds` is
                // the shared batch's whole wall time (prefill included), the
                // operation that produced this row.
                forwardSeconds: forward.suffixSeconds[index],
                totalSeconds: Self.seconds(since: started),
                promptHash: encoded[index].promptHash,
                peakMemoryBytes: Memory.peakMemory))
        }
        let result = SemanticIfSharedResult(
            scores: scores,
            prefixTokens: prefixIDs.count,
            suffixTokens: suffixes.map(\.count).reduce(0, +),
            encodeSeconds: encodeSeconds,
            prefillSeconds: forward.prefillSeconds,
            replicateSeconds: forward.replicateSeconds,
            suffixForwardSeconds: forward.suffixSeconds.reduce(0, +),
            totalSeconds: Self.seconds(since: started))
        log.info(
            "shared: \(rows.count, privacy: .public) rows over \(result.prefixTokens, privacy: .public) prefix tokens; prefill \(result.prefillSeconds, privacy: .public) s, suffixes \(result.suffixForwardSeconds, privacy: .public) s, total \(result.totalSeconds, privacy: .public) s")
        return result
    }
}

/// Aggregate result of one `scoreShared` call, mirroring the `timing` dict
/// Semif's shared.py returns alongside its per-row results.
public struct SemanticIfSharedResult: Sendable, Equatable {
    /// Per-row scores in input order; `forwardSeconds` is the row's suffix
    /// forward, `totalSeconds` the whole shared batch's wall time.
    public var scores: [SemanticIfScore]
    /// Tokens in the shared state prefix, prefilled once.
    public var prefixTokens: Int
    /// True (unpadded) suffix tokens forwarded across all rows.
    public var suffixTokens: Int
    public var encodeSeconds: Double
    public var prefillSeconds: Double
    /// Time spent deep-copying the prefilled cache, summed over rows.
    public var replicateSeconds: Double
    /// Suffix forward time, summed over rows.
    public var suffixForwardSeconds: Double
    public var totalSeconds: Double
}

/// Rejection reasons for shared mode, mirroring the ValueErrors shared.py
/// raises. A batch that hits any of these is excluded; nothing is ever
/// approximated.
enum SemanticIfSharedError: Error, Equatable {
    case noRows
    case sharedStateMismatch
    case duplicateDecisionIDs
    case payloadNotUnique
    case evidenceSerializationChanged
    case emptyPrefix
    case prefixMismatch(rowID: String)
}

/// `Sendable` inputs for the shared forward pass; every `MLXArray` is created
/// and consumed inside `ModelContainer.perform`, as in direct mode.
private struct SemanticIfSharedForwardInput: Sendable {
    var prefix: [Int32]
    var suffixes: [[Int32]]
    var answerSlots: [[Int32]]
}

extension SemanticIfPrompt {
    /// `_state_prefix` in Semif's shared.py: the token prefix that carries
    /// exactly the shared state. A placeholder row with the same state is
    /// rendered through the normal message/template path, the evidence payload
    /// (`json.dumps({"evidence": state}, ensure_ascii=False)` minus its closing
    /// brace) is located in the rendering, and the text up to and including it
    /// is encoded. The final token is dropped because appending the JSON
    /// punctuation that follows the payload can merge with it under BPE;
    /// `scoreShared` then proves the prefix is an exact token prefix of every
    /// row's full prompt, so no merge is ever assumed.
    static func statePrefixIDs<T: SemanticIfTokenizing>(
        state: SemanticIfJSON, tokenizer: T
    ) throws -> [Int32] {
        // This question text occurs after the extracted evidence boundary and
        // never reaches the prefix; only the state does.
        let probe = SemanticIfDecision(
            id: "prefix-only",
            state: state,
            question: "prefix boundary placeholder",
            options: [
                SemanticIfDecision.Option(id: "yes", description: "Yes"),
                SemanticIfDecision.Option(id: "no", description: "No"),
            ])
        let turns = try directMessages(probe)
        let prompt = try tokenizer.applyDirectChatTemplate(turns)
        let payload = turns[turns.count - 1].content
        guard let occurrence = prompt.range(of: payload),
              prompt.range(of: payload, range: occurrence.upperBound..<prompt.endIndex) == nil
        else {
            throw SemanticIfSharedError.payloadNotUnique
        }
        // `json.dumps({"evidence": state}, ensure_ascii=False)[:-1]`.
        let evidence = String(SemanticIfJSON.object([("evidence", state)]).pythonDumped.dropLast())
        guard payload.hasPrefix(evidence) else {
            throw SemanticIfSharedError.evidenceSerializationChanged
        }
        let head = String(prompt[..<occurrence.lowerBound]) + evidence
        let ids = tokenizer.encode(head)
        guard ids.count >= 2 else { throw SemanticIfSharedError.emptyPrefix }
        return Array(ids.dropLast())
    }
}
