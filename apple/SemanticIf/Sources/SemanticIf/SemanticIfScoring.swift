import Foundation

public protocol SemanticIfScoring: Sendable {
    func score(_ row: SemanticIfRow) async throws -> SemanticIfResult
}

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

    public var decision: SemanticIfDecision {
        SemanticIfDecision(id: id, state: state, question: question, options: options)
    }
}

public struct SemanticIfScore: Sendable, Equatable {
    public var rowID: String
    public var probabilities: [String: Double]
    public var argmaxOptionID: String
    public var margin: Double
    public var optionLogits: [Float]
    public var inputTokens: Int
    public var forwardSeconds: Double
    public var totalSeconds: Double
    public var promptHash: String
    public var promptVersion = "laya-coreml-choice-v1"
    public var peakMemoryBytes: Int
}

public struct SemanticIfResult: Sendable, Equatable {
    public enum Decision: Sendable, Equatable {
        case option(String)
        case uncertain
    }

    public var rowID: String
    public var probabilities: [String: Double]
    public var argmaxOptionID: String
    public var margin: Double
    public var threshold: Double
    public var decision: Decision
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

public enum SemanticIfMarginPolicy {
    public static let defaultThreshold = 0.12

    public static func decision(
        margin: Double,
        argmaxOptionID: String,
        threshold: Double = defaultThreshold
    ) -> SemanticIfResult.Decision {
        margin >= threshold ? .option(argmaxOptionID) : .uncertain
    }
}

public enum SemanticIfScorerBackend: String, Sendable, CaseIterable, Identifiable {
    case layaCoreML
    public var id: String { rawValue }
    public var displayName: String { "Laya Core ML (on this Mac)" }
}

public enum LayaAccountPrompt {
    public static let question = "What kind of screen is this?"
    public static let options: [SemanticIfDecision.Option] = [
        .init(id: "profile", description: "A social media profile page showing account information, a username, followers, or videos."),
        .init(id: "signed-out", description: "A login or sign-up screen asking the user to sign in or choose an account."),
        .init(id: "unknown", description: "A different screen or unreadable text."),
    ]

    public static func row(platform: String, ocrText: [String], visualEvidence: String? = nil) -> SemanticIfRow {
        let visual = visualEvidence?.trimmingCharacters(in: .whitespacesAndNewlines)
        let evidence = visual.flatMap { $0.isEmpty ? nil : $0 }
            ?? (ocrText.isEmpty ? "[No readable screen text]" : ocrText.joined(separator: "\n"))
        return SemanticIfRow(id: "warmup.account.\(platform.lowercased())",
            state: .string(evidence),
            question: question, options: options)
    }

    public static func hasSignInControls(_ ocrText: [String]) -> Bool {
        ocrText.contains { text in
            let label = text.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
            return label.range(of: #"^(log in|sign in|sign up)( to .+)?$|^continue with .+$"#, options: .regularExpression) != nil
        }
    }

    public static func handles(in text: String) -> [String] {
        let expression = try! NSRegularExpression(pattern: #"(?<![a-zA-Z0-9_])@([a-zA-Z0-9_.]{1,40})(?![a-zA-Z0-9_.])"#)
        let string = text as NSString
        return expression.matches(in: text, range: NSRange(location: 0, length: string.length))
            .map { string.substring(with: $0.range(at: 1)).lowercased() }
    }

    public static func outcome(surface: SemanticIfResult.Decision, expectedHandle: String,
                               observedHandles: [String], signInControlsVisible: Bool? = nil) -> String? {
        if signInControlsVisible == true { return "signed-out" }
        switch surface {
        case .option("signed-out"): return signInControlsVisible == false ? "unreadable" : "signed-out"
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
