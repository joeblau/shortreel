import Foundation

/// The scoring interface the rest of the app talks to (issue #14). Callers
/// never see MLX: the in-process backend ships first, and a llama.cpp
/// sidecar (Route A) can be added later behind this same protocol.
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

/// One scored decision, mirroring the fields direct.py's `score` returns.
/// Kept in this MLX-free file so standalone swiftc suites can build results
/// for stub scorers (issue #15).
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
/// caller routes to `needsInput`. Semif's own rows mark the softmax
/// "conditional option score; uncalibrated as decision confidence", so the
/// threshold is tuned on our fixtures, not assumed.
public enum SemanticIfMarginPolicy {
    /// Default 0.12, matching the issue #13 parity tolerance (see
    /// `Fixtures/PARITY.md`): the largest observed probability deviation
    /// between this MLX port and Semif's published BF16 rows is 0.1152, so a
    /// margin below 0.12 can be an artifact of cross-runtime BF16
    /// accumulation rather than a real preference. On the 147 parity fixture
    /// rows this marks the 7 rows with margins 0.059–0.118 uncertain and
    /// leaves the other 140 decided; argmax agreement on those 7 was still
    /// 100 %, so nothing the fixtures prove correct is flipped.
    public static let defaultThreshold = 0.12

    public static func decision(
        margin: Double,
        argmaxOptionID: String,
        threshold: Double = defaultThreshold
    ) -> SemanticIfResult.Decision {
        margin >= threshold ? .option(argmaxOptionID) : .uncertain
    }
}

/// Which backend supplies local scoring. Only the in-process MLX backend
/// ships today; the llama.cpp sidecar (Route A) lands here as another case
/// behind `SemanticIfScoring`.
public enum SemanticIfScorerBackend: String, Sendable, CaseIterable, Identifiable {
    case mlx

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .mlx: "MLX (on this Mac)"
        }
    }
}

