import Foundation

/// Shared classification interface. Laya Core ML supplies local decisions;
/// the existing name preserves the warm-up runner and journal contracts.
public protocol SemanticIfScoring: Sendable {
    /// Scores one decision row. The result carries the margin-policy verdict,
    /// so callers route `.uncertain` to `needsInput` without re-implementing
    /// the threshold.
    func score(_ row: SemanticIfRow) async throws -> SemanticIfResult
}

/// One decision row, as the protocol exposes it. This deliberately mirrors
/// `SemanticIfDecision`'s fields instead of aliasing it, so the protocol
/// contract stays stable if the Semif port's internals change.
public struct SemanticIfRow: Sendable, Equatable {
    public var id: String
    public var state: SemanticIfJSON
    public var question: String
    public var options: [SemanticIfDecision.Option]

    public init(id: String, state: SemanticIfJSON, question: String, options: [SemanticIfDecision.Option]) {
        self.id = id
        self.state = state
        self.question = question
        self.options = options
    }

    public init(_ decision: SemanticIfDecision) {
        self.init(id: decision.id, state: decision.state, question: decision.question, options: decision.options)
    }

    /// The Semif-port decision this row encodes, validated on `score`.
    public var decision: SemanticIfDecision {
        SemanticIfDecision(id: id, state: state, question: question, options: options)
    }
}

/// One scored decision and its diagnostics, shared with standalone runner tests.
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
    public var promptVersion = "laya-coreml-choice-v1"
    public var peakMemoryBytes: Int
}

/// One scored row plus the margin-policy verdict. `decision` is the only
/// field callers need to act on; everything else is diagnostics.
public struct SemanticIfResult: Sendable, Equatable {
    public enum Decision: Sendable, Equatable {
        /// The argmax option wins: its margin cleared the threshold.
        case option(String)
        /// Top two options are too close to trust; route to `needsInput`.
        case uncertain
    }

    public var rowID: String
    /// Probability of each option id, in the row's declared option order.
    public var probabilities: [String: Double]
    public var argmaxOptionID: String
    /// Top probability minus runner-up probability.
    public var margin: Double
    /// The threshold the margin was judged against.
    public var threshold: Double
    public var decision: Decision
    /// Full readout diagnostics: logits, timings, prompt hash, peak memory.
    public var score: SemanticIfScore

    public init(score: SemanticIfScore, threshold: Double = SemanticIfMarginPolicy.defaultThreshold) {
        self.rowID = score.rowID
        self.probabilities = score.probabilities
        self.argmaxOptionID = score.argmaxOptionID
        self.margin = score.margin
        self.threshold = threshold
        self.decision = SemanticIfMarginPolicy.decision(margin: score.margin, argmaxOptionID: score.argmaxOptionID, threshold: threshold)
        self.score = score
    }
}

/// The margin rule, in exactly one place: argmax wins only if
/// `p(top) − p(second) ≥ threshold`; anything closer is `.uncertain` and the
/// caller routes to `needsInput`. A probability margin is not an accuracy guarantee.
public enum SemanticIfMarginPolicy {
    /// Retained as the application's minimum decision margin. This is a
    /// routing policy, not a calibrated accuracy guarantee for Laya.
    public static let defaultThreshold = 0.12

    public static func decision(
        margin: Double,
        argmaxOptionID: String,
        threshold: Double = defaultThreshold
    ) -> SemanticIfResult.Decision {
        margin >= threshold ? .option(argmaxOptionID) : .uncertain
    }
}

/// The local classification runtime; no Python process or MLX dependency.
public enum SemanticIfScorerBackend: String, Sendable, CaseIterable, Identifiable {
    case layaCoreML
    public var id: String { rawValue }
    public var displayName: String { "Laya Core ML (on this Mac)" }
}

/// Classify the screen semantically; compare identifiers exactly in the caller.
/// A language model's similarity judgment must never authorize a different account.
public enum LayaAccountPrompt {
    public static let question = "What kind of screen is this?"
    public static let options: [SemanticIfDecision.Option] = [
        .init(id: "profile", description: "A social media profile page showing account information, a username, followers, or videos."),
        .init(id: "signed-out", description: "A login or sign-up screen asking the user to sign in or choose an account."),
        .init(id: "unknown", description: "A different screen or unreadable text."),
    ]

    public static func row(platform: String, ocrText: [String]) -> SemanticIfRow {
        SemanticIfRow(id: "warmup.account.\(platform.lowercased())",
            state: .string(ocrText.isEmpty ? "[No readable screen text]" : ocrText.joined(separator: "\n")),
            question: question, options: options)
    }

    public static func handles(in text: String) -> [String] {
        let expression = try! NSRegularExpression(pattern: #"(?<![a-zA-Z0-9_])@([a-zA-Z0-9_.]{1,40})(?![a-zA-Z0-9_.])"#)
        let string = text as NSString
        return expression.matches(in: text, range: NSRange(location: 0, length: string.length))
            .map { string.substring(with: $0.range(at: 1)).lowercased() }
    }

    /// No handle or conflicting handles means unreadable. Only a confident
    /// profile classification with one exact, case-insensitive match can pass.
    public static func outcome(surface: SemanticIfResult.Decision, expectedHandle: String,
                               observedHandles: [String]) -> String? {
        switch surface {
        case .option("signed-out"): return "signed-out"
        case .option("profile"):
            func normalize(_ handle: String) -> String {
                String(handle.trimmingCharacters(in: .whitespacesAndNewlines).drop(while: { $0 == "@" })).lowercased()
            }
            let handles = Set(observedHandles.map(normalize).filter { !$0.isEmpty })
            guard handles.count == 1, let observed = handles.first else { return "unreadable" }
            return observed == normalize(expectedHandle) ? "matches" : "mismatch"
        case .option("unknown"), .uncertain: return "unreadable"
        case .option: return nil
        }
    }
}
