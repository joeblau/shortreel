import Foundation

/// The warm-up account step decided locally (contract TASK-8, issue #15): the
/// CURRENT frame's OCR text, the persona handle, and the platform's
/// accountLocation identify the check. Laya classifies the screen surface;
/// an exact username comparison finishes the step or stops the run before
/// any engagement input. Missing or failed scoring stops the transaction.
///
/// The contract strings below are the single Swift copy of the account step's
/// success criteria and failure-mode detection text; `WarmUpTasksContractTests`
/// asserts they match `Contracts/warmup-tasks.json` for every platform.
enum WarmUpAccountClassifier {
    /// One contract `failureModes[]` entry's id and detection text.
    struct FailureMode: Equatable, Sendable {
        let id: String
        let detection: String
    }

    enum ClassifierError: Error, Equatable {
        /// The contract's account step lost a failure mode the row maps from.
        case missingFailureMode(String)
        /// The scorer returned an option the row never declared.
        case unknownOption(String)
    }

    /// Option ids in declaration order (letters A–D in the scored prompt).
    static let optionIDs = ["matches", "mismatch", "signed-out", "unreadable"]

    /// The account step's success criteria, verbatim from the contract (its
    /// criteria list's first item is the platform's accountLocation, supplied
    /// separately as scorer state).
    static let successCriteria = "OCR shows '@' + persona.handle (case-insensitive) in the profile header on the CURRENT frame; no sign-in / account-picker surface visible"

    /// The account step's `failureModes` detection text, verbatim from the
    /// contract. `wrong-app` is navigation recovery, not a classifier option.
    static let failureModes: [FailureMode] = [
        FailureMode(id: "signed-out",
            detection: "screen.state == foregroundApp and OCR finds 'Log in' / 'Sign up' / 'Continue with'"),
        FailureMode(id: "handle-mismatch",
            detection: "OCR handle (case-insensitive, '@' stripped) != persona.handle"),
        FailureMode(id: "handle-unreadable",
            detection: "profile visible but no '@' token with confidence >= 0.6 after 3 fresh frames"),
    ]

    /// The four decision options: `matches` describes the success criteria;
    /// the failure options carry the contract's detection text. Throws when a
    /// contract failure mode the row maps from is missing.
    static func options(successCriteria: String = Self.successCriteria,
                        failureModes: [FailureMode] = Self.failureModes) throws -> [SemanticIfDecision.Option] {
        func detection(_ id: String) throws -> String {
            guard let mode = failureModes.first(where: { $0.id == id }) else {
                throw ClassifierError.missingFailureMode(id)
            }
            return mode.detection
        }
        return [
            .init(id: "matches", description: successCriteria),
            .init(id: "mismatch", description: try detection("handle-mismatch")),
            .init(id: "signed-out", description: try detection("signed-out")),
            .init(id: "unreadable", description: try detection("handle-unreadable")),
        ]
    }

    /// Laya classifies screen type; exact username matching happens after
    /// classification. Contract metadata remains owned by the warm-up runner.
    static func row(platform: String, accountLocation: String, handle: String, ocrText: [String],
                    successCriteria: String = Self.successCriteria,
                    failureModes: [FailureMode] = Self.failureModes, visualEvidence: String? = nil) throws -> SemanticIfRow {
        _ = try options(successCriteria: successCriteria, failureModes: failureModes)
        return LayaAccountPrompt.row(platform: platform, ocrText: ocrText, visualEvidence: visualEvidence)
    }

    /// OCR the current frame with the submission guard's recognizer and score
    /// it. An OCR failure reads as no regions: the scorer sees empty evidence
    /// and the contract's unreadable recovery applies.
    static func classify(frame: PhoneScreenFrame, platform: String, accountLocation: String,
                         handle: String, scorer: any SemanticIfScoring,
                         observation: PhoneScreenObservation? = nil) async throws -> WarmUpAccountDecision {
        let regions = (try? await PhoneSubmissionGuard.recognizeText(in: frame)) ?? []
        return try await classify(regions: regions, platform: platform, accountLocation: accountLocation,
            handle: handle, scorer: scorer, observation: observation)
    }

    /// Score already-recognized regions. `.uncertain` (margin below the tuned
    /// threshold) is unreadable; only a saved navigation branch may run, and
    /// unreadable evidence can never complete the account phase.
    static func classify(regions: [PhoneSubmissionGuard.TextRegion], platform: String, accountLocation: String,
                         handle: String, scorer: any SemanticIfScoring,
                         observation: PhoneScreenObservation? = nil) async throws -> WarmUpAccountDecision {
        let handle = String(handle.trimmingCharacters(in: .whitespacesAndNewlines).drop(while: { $0 == "@" }))
        let ordered = regions.sorted { ($0.bounds.minY, $0.bounds.minX) < ($1.bounds.minY, $1.bounds.minX) }
        let row = try row(platform: platform, accountLocation: accountLocation,
            handle: handle, ocrText: ordered.map(\.text), visualEvidence: observation?.checkEvidence ?? observation?.evidence)
        let result = try await scorer.score(row)
        guard let selected = LayaAccountPrompt.outcome(surface: result.decision,
            expectedHandle: handle, observedHandles: readableHandles(in: ordered),
            signInControlsVisible: LayaAccountPrompt.hasSignInControls(ordered.filter { $0.confidence >= 0.6 }.map(\.text))),
            let outcome = WarmUpAccountDecision.Outcome(rawValue: selected) else {
            throw ClassifierError.unknownOption(result.argmaxOptionID)
        }
        let evidence: String
        switch outcome {
        case .matches:
            evidence = "Local account check: the \(platform) profile shows @\(handle)."
        case .mismatch:
            let observed = observedHandle(in: ordered).map { "@\($0)" } ?? "a different handle"
            evidence = "The \(platform) profile shows \(observed), not the persona's @\(handle). Sign the phone into @\(handle) or update the persona, then run again. No input was sent."
        case .signedOut:
            evidence = "\(platform) is signed out or showing a sign-in screen. Sign in as @\(handle) on the phone itself; ShortReel never enters credentials. No input was sent."
        case .unreadable:
            evidence = "The \(platform) profile handle could not be read from the current screen."
        }
        return WarmUpAccountDecision(outcome: outcome, evidence: evidence,
            probabilities: result.probabilities, margin: result.margin,
            threshold: result.threshold, promptHash: result.score.promptHash)
    }

    /// Only high-confidence OCR tokens can identify an account. Multiple
    /// different handles are ambiguous (for example a bio mentioning someone).
    static func readableHandles(in regions: [PhoneSubmissionGuard.TextRegion]) -> [String] {
        regions.filter { $0.confidence >= 0.6 }.flatMap { LayaAccountPrompt.handles(in: $0.text) }
    }

    static func observedHandle(in regions: [PhoneSubmissionGuard.TextRegion]) -> String? {
        readableHandles(in: regions).first
    }
}
