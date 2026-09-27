import Foundation

enum WarmUpAccountClassifier {
    struct FailureMode: Equatable, Sendable {
        let id: String
        let detection: String
    }

    enum ClassifierError: Error, Equatable {
        case missingFailureMode(String)
        case unknownOption(String)
    }

    static let optionIDs = ["matches", "mismatch", "signed-out", "unreadable"]

    static let successCriteria = "OCR shows '@' + persona.handle (case-insensitive) in the profile header on the CURRENT frame; no sign-in / account-picker surface visible"

    static let failureModes: [FailureMode] = [
        FailureMode(id: "signed-out",
            detection: "screen.state == foregroundApp and OCR finds 'Log in' / 'Sign up' / 'Continue with'"),
        FailureMode(id: "handle-mismatch",
            detection: "own-profile markers visible and the header OCR handle (confidence >= 0.85, case-insensitive, '@' stripped) != persona.handle"),
        FailureMode(id: "handle-unreadable",
            detection: "profile visible but no '@' token with confidence >= 0.6 after 3 fresh frames"),
    ]

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

    static func row(platform: String, accountLocation: String, handle: String, ocrText: [String],
                    successCriteria: String = Self.successCriteria,
                    failureModes: [FailureMode] = Self.failureModes, visualEvidence: String? = nil) throws -> SemanticIfRow {
        _ = try options(successCriteria: successCriteria, failureModes: failureModes)
        return LayaAccountPrompt.row(platform: platform, ocrText: ocrText, visualEvidence: visualEvidence)
    }

    static func classify(frame: PhoneScreenFrame, platform: String, accountLocation: String,
                         handle: String, scorer: any SemanticIfScoring,
                         observation: PhoneScreenObservation? = nil) async throws -> WarmUpAccountDecision {
        let regions = (try? await PhoneSubmissionGuard.recognizeText(in: frame)) ?? []
        return try await classify(regions: regions, platform: platform, accountLocation: accountLocation,
            handle: handle, scorer: scorer, observation: observation)
    }

    static func classify(regions: [PhoneSubmissionGuard.TextRegion], platform: String, accountLocation: String,
                         handle: String, scorer: any SemanticIfScoring,
                         observation: PhoneScreenObservation? = nil) async throws -> WarmUpAccountDecision {
        let handle = String(handle.trimmingCharacters(in: .whitespacesAndNewlines).drop(while: { $0 == "@" }))
        let ordered = regions.sorted { ($0.bounds.minY, $0.bounds.minX) < ($1.bounds.minY, $1.bounds.minX) }
        let row = try row(platform: platform, accountLocation: accountLocation,
            handle: handle, ocrText: ordered.map(\.text), visualEvidence: observation?.checkEvidence ?? observation?.evidence)
        let ownProfile = PhoneScreenSignal.ownProfile.matches(ordered.map {
            .init(text: $0.text, confidence: $0.confidence, bounds: $0.bounds)
        }, network: WarmUpScript.Network(rawValue: platform))
        let signIn = LayaAccountPrompt.hasSignInControls(ordered.filter { $0.confidence >= 0.6 }.map(\.text))
        // Own-profile OCR already proves the surface, so Laya is asked only when those markers are missing.
        let result: SemanticIfResult? = if ownProfile && !signIn { nil } else { try await scorer.score(row) }
        guard var selected = LayaAccountPrompt.outcome(surface: result?.decision ?? .option("profile"),
            expectedHandle: handle, observedHandles: readableHandles(in: ordered, platform: platform),
            signInControlsVisible: signIn, ownProfileVisible: ownProfile) else {
            throw ClassifierError.unknownOption(result?.argmaxOptionID ?? "profile")
        }
        if selected == "mismatch", readableHandles(in: ordered.filter { $0.confidence >= 0.85 }, platform: platform).isEmpty {
            selected = "unreadable"
        }
        guard let outcome = WarmUpAccountDecision.Outcome(rawValue: selected) else {
            throw ClassifierError.unknownOption(result?.argmaxOptionID ?? "profile")
        }
        let evidence: String
        switch outcome {
        case .matches:
            evidence = "Local account check: the \(platform) profile shows @\(handle)."
        case .mismatch:
            let observed = observedHandle(in: ordered, platform: platform).map { "@\($0)" } ?? "a different handle"
            evidence = "The \(platform) profile shows \(observed), not the persona's @\(handle). Sign the phone into @\(handle) or update the persona, then run again. No input was sent."
        case .signedOut:
            evidence = "\(platform) is signed out or showing a sign-in screen. Sign in as @\(handle) on the phone itself; ShortReel never enters credentials. No input was sent."
        case .unreadable:
            evidence = "The \(platform) profile handle could not be read from the current screen."
        }
        return WarmUpAccountDecision(outcome: outcome, evidence: evidence,
            probabilities: result?.probabilities ?? ["profile": 1], margin: result?.margin ?? 1,
            threshold: result?.threshold ?? SemanticIfMarginPolicy.defaultThreshold, promptHash: result?.score.promptHash ?? "")
    }

    static func readableHandles(in regions: [PhoneSubmissionGuard.TextRegion], platform: String = "") -> [String] {
        LayaAccountPrompt.headerHandles(regions.filter { $0.confidence >= 0.6 }.map { ($0.text, Double($0.bounds.minY)) },
            platform: platform)
    }

    static func observedHandle(in regions: [PhoneSubmissionGuard.TextRegion], platform: String = "") -> String? {
        readableHandles(in: regions, platform: platform).first
    }
}
