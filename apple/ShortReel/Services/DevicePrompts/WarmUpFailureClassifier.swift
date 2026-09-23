import Foundation

enum WarmUpFailureClassifier {
    static let question = "Which failure mode, if any, is supported by the current screen and playback evidence? Choose none if no listed failure mode is supported."
    enum ClassifierError: Error, Equatable {
        case unknownOption(String)
    }

    static func attemptLimit(for modeID: String) -> Int {
        switch modeID {
        case "search-not-focused": return 2
        default: return 1
        }
    }

    static func options(step: WarmUpStepContract) -> [SemanticIfDecision.Option] {
        [.init(id: "none", description: "No failure mode is visible on the CURRENT frame; the step's success criteria are being met or are still reachable without recovery.")]
            + step.failureModes.map { .init(id: $0.id, description: $0.detection) }
    }

    static func row(scriptIdentifier: String, platform: String, step: WarmUpStepContract,
                    screenState: String, playbackSummary: String?, ocrText: [String]) -> SemanticIfRow {
        SemanticIfRow(
            id: "\(scriptIdentifier).\(step.id)",
            state: .object([
                ("platform", .string(platform)),
                ("step", .string(step.title)),
                ("successCriteria", .array(step.successCriteria.map { .string($0) })),
                ("screenState", .string(screenState)),
                ("playbackEvidence", .string(playbackSummary ?? "No local playback evidence for this step.")),
                ("ocrText", .array(ocrText.map { .string($0) })),
            ]),
            question: question,
            options: options(step: step))
    }

    static func classify(frame: PhoneScreenFrame, scriptIdentifier: String, platform: String,
                         step: WarmUpStepContract, playbackSummary: String?,
                         scorer: any SemanticIfScoring) async throws -> WarmUpFailureDecision {
        let regions = (try? await PhoneSubmissionGuard.recognizeText(in: frame)) ?? []
        return try await classify(regions: regions, scriptIdentifier: scriptIdentifier, platform: platform,
            step: step, playbackSummary: playbackSummary, scorer: scorer)
    }

    static func classify(regions: [PhoneSubmissionGuard.TextRegion], scriptIdentifier: String, platform: String,
                         step: WarmUpStepContract, playbackSummary: String?, screenState: String = "foregroundApp",
                         scorer: any SemanticIfScoring) async throws -> WarmUpFailureDecision {
        let ordered = regions.sorted { ($0.bounds.minY, $0.bounds.minX) < ($1.bounds.minY, $1.bounds.minX) }
        let row = row(scriptIdentifier: scriptIdentifier, platform: platform, step: step,
            screenState: screenState, playbackSummary: playbackSummary, ocrText: ordered.map(\.text))
        let result = try await scorer.score(row)
        switch result.decision {
        case .option("none"):
            return WarmUpFailureDecision(stepID: step.id, failureModeID: nil, uncertain: false,
                terminal: false, detection: "", recovery: "",
                evidence: "Local failure-mode check: no \(step.title) failure mode is visible on the current frame.",
                probabilities: result.probabilities, margin: result.margin,
                threshold: result.threshold, promptHash: result.score.promptHash)
        case .uncertain:
            return WarmUpFailureDecision(stepID: step.id, failureModeID: nil, uncertain: true,
                terminal: false, detection: "", recovery: "",
                evidence: "Local failure-mode check for \(step.title) was too close to call; no input is authorized.",
                probabilities: result.probabilities, margin: result.margin,
                threshold: result.threshold, promptHash: result.score.promptHash)
        case .option(let id):
            guard let mode = step.failureModes.first(where: { $0.id == id }) else {
                throw ClassifierError.unknownOption(id)
            }
            return WarmUpFailureDecision(stepID: step.id, failureModeID: id, uncertain: false,
                terminal: mode.terminal, detection: mode.detection, recovery: mode.recovery,
                evidence: "Local failure-mode check: \(step.title) shows '\(id)' (\(mode.detection)).",
                probabilities: result.probabilities, margin: result.margin,
                threshold: result.threshold, promptHash: result.score.promptHash)
        }
    }
}

struct WarmUpStepBudget: Equatable, Sendable {
    let maxPlannerDecisions: Int
    let maxSeconds: Int
}

struct WarmUpStepContract: Equatable, Sendable {
    struct FailureMode: Equatable, Sendable {
        let id: String
        let detection: String
        let recovery: String
        let terminal: Bool
    }

    let id: String
    let title: String
    let successCriteria: [String]
    let failureModes: [FailureMode]
    let budget: WarmUpStepBudget
}

struct WarmUpContractStore: Equatable, Sendable {
    private let stepsByScript: [String: [String: WarmUpStepContract]]

    init(data: Data) throws {
        let contract = try JSONDecoder().decode(ContractJSON.self, from: data)
        var stepsByScript: [String: [String: WarmUpStepContract]] = [:]
        for platform in contract.platforms.values {
            for activity in platform.activities.values {
                var steps: [String: WarmUpStepContract] = [:]
                for step in activity.steps {
                    steps[step.id] = WarmUpStepContract(
                        id: step.id, title: step.title,
                        successCriteria: step.successCriteria,
                        failureModes: step.failureModes.map {
                            .init(id: $0.id, detection: $0.detection, recovery: $0.recovery,
                                  terminal: $0.terminal ?? false)
                        },
                        budget: WarmUpStepBudget(maxPlannerDecisions: step.budget.maxPlannerDecisions,
                            maxSeconds: step.budget.maxSeconds))
                }
                stepsByScript[activity.scriptIdentifier] = steps
            }
        }
        self.stepsByScript = stepsByScript
    }

    static func bundled(in bundle: Bundle = .main) -> WarmUpContractStore? {
        guard let url = bundle.url(forResource: "warmup-tasks", withExtension: "json"),
              let data = try? Data(contentsOf: url) else { return nil }
        return try? WarmUpContractStore(data: data)
    }

    func step(scriptIdentifier: String, stepID: String) -> WarmUpStepContract? {
        stepsByScript[scriptIdentifier]?[stepID]
    }

    var stepCount: Int { stepsByScript.values.reduce(0) { $0 + $1.count } }
    var failureModeCount: Int { stepsByScript.values.reduce(0) { $0 + $1.values.reduce(0) { $0 + $1.failureModes.count } } }

    private struct ContractJSON: Decodable {
        struct FailureMode: Decodable { let id: String; let detection: String; let recovery: String; let terminal: Bool? }
        struct Budget: Decodable { let maxPlannerDecisions: Int; let maxSeconds: Int }
        struct Step: Decodable {
            let id: String; let title: String; let successCriteria: [String]
            let failureModes: [FailureMode]; let budget: Budget
        }
        struct Activity: Decodable { let scriptIdentifier: String; let steps: [Step] }
        struct Platform: Decodable { let activities: [String: Activity] }
        let platforms: [String: Platform]
    }
}
