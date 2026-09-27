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

    static let none = SemanticIfDecision.Option(id: "none", description: "No listed problem is visible.")
    static let maximumOCRLines = 60
    /// Dense OCR (digits, emoji) reaches Laya's 1,024-token window at about 950 UTF-8 bytes.
    static let maximumOCRBytes = 900

    /// Only non-terminal failure modes visible in a single frame are offered, and only when their OCR rule matches `ocrText`
    /// and their `absentSignal` does not; terminal modes are read from banner OCR, never from Laya.
    static func options(step: WarmUpStepContract, ocrText: [String]? = nil, signals: Set<PhoneScreenSignal> = []) -> [SemanticIfDecision.Option] {
        [none] + step.failureModes.filter { mode in
            mode.observable && !mode.terminal && (mode.ocrRule == nil || ocrText.map(mode.ruleMatches) ?? true)
                && mode.absentSignal.map { !signals.contains($0) } ?? true
        }.map { .init(id: $0.id, description: $0.visible) }
    }

    static func row(scriptIdentifier: String, platform: String, step: WarmUpStepContract,
                    screenState: String, playbackSummary: String?, ocrText: [String], signals: Set<PhoneScreenSignal> = []) -> SemanticIfRow {
        let options = options(step: step, ocrText: ocrText, signals: signals)
        let rules = step.failureModes.filter { mode in options.contains { $0.id == mode.id } }
        return SemanticIfRow(
            id: "\(scriptIdentifier).\(step.id)",
            state: .object([
                ("platform", .string(platform)),
                ("step", .string(step.title)),
                ("screenState", .string(screenState)),
                ("playbackEvidence", .string(playbackSummary ?? "No local playback evidence for this step.")),
                ("ocrText", .array(evidence(ocrText, keeping: { line in rules.contains { $0.ruleMatches([line]) } }).map { .string($0) })),
            ]),
            question: question,
            options: options)
    }

    /// Reading-order OCR within Laya's input limit, keeping the lines that matched an offered mode's rule.
    static func evidence(_ lines: [String], keeping keep: (String) -> Bool) -> [String] {
        var bytes = maximumOCRBytes
        var kept = Set<Int>()
        for index in lines.indices.filter({ keep(lines[$0]) }) + lines.indices.filter({ !keep(lines[$0]) })
        where kept.count < maximumOCRLines && lines[index].utf8.count <= bytes {
            kept.insert(index)
            bytes -= lines[index].utf8.count
        }
        return lines.indices.filter(kept.contains).map { lines[$0] }
    }

    static func classify(frame: PhoneScreenFrame, observation: PhoneScreenObservation?, scriptIdentifier: String, platform: String,
                         step: WarmUpStepContract, playbackSummary: String?,
                         scorer: any SemanticIfScoring) async throws -> WarmUpFailureDecision {
        guard step.failureModes.contains(where: \.observable) else { return unobserved(step) }
        let regions = (try? await PhoneSubmissionGuard.recognizeText(in: frame)) ?? []
        return try await classify(regions: regions, scriptIdentifier: scriptIdentifier, platform: platform,
            step: step, playbackSummary: playbackSummary, screenState: observation?.state.rawValue ?? "foregroundApp", scorer: scorer)
    }

    static func classify(regions: [PhoneSubmissionGuard.TextRegion], scriptIdentifier: String, platform: String,
                         step: WarmUpStepContract, playbackSummary: String?, screenState: String = "foregroundApp",
                         scorer: any SemanticIfScoring) async throws -> WarmUpFailureDecision {
        let confident = regions.filter { $0.confidence >= 0.6 }
            .sorted { ($0.bounds.minY, $0.bounds.minX) < ($1.bounds.minY, $1.bounds.minX) }
        let lines = confident.map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        // An app error is a toast, banner, or alert; body text such as other people's comments never stops a run.
        let banner = confident.filter { screenState == "dialog" || $0.bounds.minY < 0.2 || $0.bounds.maxY > 0.8 }.map(\.text)
        if let mode = step.failureModes.first(where: { $0.observable && $0.terminal && $0.ruleMatches(banner) }) {
            return WarmUpFailureDecision(stepID: step.id, failureModeID: mode.id, uncertain: false, terminal: true,
                detection: mode.detection, recovery: mode.recovery,
                evidence: "Local failure-mode check: \(step.title) shows '\(mode.id)' (\(mode.detection)).",
                probabilities: [mode.id: 1], margin: 1, threshold: SemanticIfMarginPolicy.defaultThreshold, promptHash: "")
        }
        let signals = PhoneScreenSignal.matching(confident.map { .init(text: $0.text, confidence: $0.confidence, bounds: $0.bounds) },
            network: WarmUpScript.Network(rawValue: platform))
        guard options(step: step, ocrText: lines, signals: signals).count > 1 else { return unobserved(step) }
        let row = row(scriptIdentifier: scriptIdentifier, platform: platform, step: step,
            screenState: screenState, playbackSummary: playbackSummary, ocrText: lines, signals: signals)
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
            guard let mode = step.failureModes.first(where: { $0.id == id }), row.options.contains(where: { $0.id == id }) else {
                throw ClassifierError.unknownOption(id)
            }
            return WarmUpFailureDecision(stepID: step.id, failureModeID: id, uncertain: false,
                terminal: mode.terminal && mode.ruleMatches(lines), detection: mode.detection, recovery: mode.recovery,
                evidence: "Local failure-mode check: \(step.title) shows '\(id)' (\(mode.detection)).",
                probabilities: result.probabilities, margin: result.margin,
                threshold: result.threshold, promptHash: result.score.promptHash)
        }
    }

    /// No observable mode applies to this frame, so Laya is not asked.
    static func unobserved(_ step: WarmUpStepContract) -> WarmUpFailureDecision {
        WarmUpFailureDecision(stepID: step.id, failureModeID: nil, uncertain: false, terminal: false, detection: "", recovery: "",
            evidence: "Local failure-mode check: no observable \(step.title) failure mode applies to the current frame.",
            probabilities: ["none": 1], margin: 1, threshold: SemanticIfMarginPolicy.defaultThreshold, promptHash: "")
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
        var observable = false
        var visible = ""
        var ocrRule: String? = nil
        var absentSignal: PhoneScreenSignal? = nil

        /// Whether a confident OCR line matches `ocrRule`; a terminal mode needs this before it can stop a run.
        func ruleMatches(_ lines: [String]) -> Bool {
            guard let ocrRule else { return false }
            return lines.contains {
                $0.replacingOccurrences(of: "’", with: "'").split(whereSeparator: \.isWhitespace).joined(separator: " ")
                    .range(of: ocrRule, options: [.regularExpression, .caseInsensitive]) != nil
            }
        }
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
                                  terminal: $0.terminal ?? false, observable: $0.observable ?? false,
                                  visible: $0.visible ?? "", ocrRule: $0.ocrRule, absentSignal: $0.absentSignal)
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
        struct FailureMode: Decodable {
            let id: String; let detection: String; let recovery: String; let terminal: Bool?
            let observable: Bool?; let visible: String?; let ocrRule: String?; let absentSignal: PhoneScreenSignal?
        }
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
