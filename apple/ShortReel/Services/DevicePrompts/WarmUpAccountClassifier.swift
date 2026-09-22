import Foundation

/// The warm-up account step decided locally (contract TASK-8, issue #15): the
/// CURRENT frame's OCR text, the persona handle, and the platform's
/// accountLocation form one SemanticIf decision row; the local scorer's
/// margin-policy verdict finishes the step or stops the run before any
/// engagement input. A nil verdict from the caller means no scorer is loaded
/// and the run takes exactly the planner-only path of today.
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

    /// The scored row: platform, expected handle, and where the handle appears
    /// as context; the current frame's OCR lines (top to bottom) as evidence.
    static func row(platform: String, accountLocation: String, handle: String, ocrText: [String],
                    successCriteria: String = Self.successCriteria,
                    failureModes: [FailureMode] = Self.failureModes) throws -> SemanticIfRow {
        SemanticIfRow(
            id: "warmup.account.\(platform.lowercased())",
            state: .object([
                ("platform", .string(platform)),
                ("expectedHandle", .string("@" + handle)),
                ("accountLocation", .string(accountLocation)),
                ("ocrText", .array(ocrText.map { .string($0) })),
            ]),
            question: successCriteria,
            options: try options(successCriteria: successCriteria, failureModes: failureModes))
    }

    /// OCR the current frame with the submission guard's recognizer and score
    /// it. An OCR failure reads as no regions: the scorer sees empty evidence
    /// and the contract's unreadable recovery applies.
    static func classify(frame: PhoneScreenFrame, platform: String, accountLocation: String,
                         handle: String, scorer: any SemanticIfScoring) async throws -> WarmUpAccountDecision {
        let regions = (try? await PhoneSubmissionGuard.recognizeText(in: frame)) ?? []
        return try await classify(regions: regions, platform: platform, accountLocation: accountLocation,
            handle: handle, scorer: scorer)
    }

    /// Score already-recognized regions. `.uncertain` (margin below the tuned
    /// threshold) is the contract's unreadable path; the runner applies the
    /// one-Home-plus-reopen recovery before needsInput.
    static func classify(regions: [PhoneSubmissionGuard.TextRegion], platform: String, accountLocation: String,
                         handle: String, scorer: any SemanticIfScoring) async throws -> WarmUpAccountDecision {
        let ordered = regions.sorted { ($0.bounds.minY, $0.bounds.minX) < ($1.bounds.minY, $1.bounds.minX) }
        let row = try row(platform: platform, accountLocation: accountLocation,
            handle: handle, ocrText: ordered.map(\.text))
        let result = try await scorer.score(row)
        let outcome: WarmUpAccountDecision.Outcome
        let evidence: String
        switch result.decision {
        case .option("matches"):
            outcome = .matches
            evidence = "Local account check: the \(platform) profile shows @\(handle)."
        case .option("mismatch"):
            outcome = .mismatch
            let observed = observedHandle(in: regions).map { "@\($0)" } ?? "an unreadable or different handle"
            evidence = "The \(platform) profile shows \(observed), not the persona's @\(handle). Sign the phone into @\(handle) or update the persona, then run again. No input was sent."
        case .option("signed-out"):
            outcome = .signedOut
            evidence = "\(platform) is signed out or showing a sign-in screen. Sign in as @\(handle) on the phone itself; ShortReel never enters credentials. No input was sent."
        case .option("unreadable"), .uncertain:
            outcome = .unreadable
            evidence = "The \(platform) profile handle could not be read from the current screen."
        case .option(let other):
            throw ClassifierError.unknownOption(other)
        }
        return WarmUpAccountDecision(outcome: outcome, evidence: evidence,
            probabilities: result.probabilities, margin: result.margin,
            threshold: result.threshold, promptHash: result.score.promptHash)
    }

    /// The handle the screen shows, for the mismatch message: the first
    /// '@'-prefixed token OCR read, normalized the way the contract compares.
    static func observedHandle(in regions: [PhoneSubmissionGuard.TextRegion]) -> String? {
        for region in regions {
            let text = region.text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
            guard let match = text.range(of: #"@([a-z0-9_.]{1,40})"#, options: .regularExpression) else { continue }
            return String(text[match].dropFirst())
        }
        return nil
    }
}
