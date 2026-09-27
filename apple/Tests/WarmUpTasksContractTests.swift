import CoreGraphics
import Foundation

@main
enum WarmUpTasksContractTests {
    enum Failure: Error { case assertion(String) }
    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw Failure.assertion(message) }
    }

    struct Contract: Decodable {
        struct Invariant: Decodable { let id: String; let rule: String; let enforcedBy: String }
        struct FailureMode: Decodable {
            let id: String; let detection: String; let recovery: String; let terminal: Bool?
            let observable: Bool?; let visible: String?; let ocrRule: String?
        }
        struct Budget: Decodable { let maxPlannerDecisions: Int; let maxSeconds: Int }
        struct Step: Decodable {
            let id: WarmUpScript.StepID; let title: String
            let preconditions: [String]; let successCriteria: [String]
            let allowedActions: [String]; let forbiddenActions: [String]
            let failureModes: [FailureMode]; let budget: Budget
            let submitControlLabels: [String]?
            let maximumVideoDurationSeconds: Int?
        }
        struct Limits: Decodable { let itemLimit: Range; let maxDurationSeconds: Int; struct Range: Decodable { let min: Int; let max: Int } }
        struct Activity: Decodable {
            let scriptIdentifier: String; let version: Int; let limits: Limits
            let retryPolicy: WarmUpScript.RetryPolicy; let successCase: String; let steps: [Step]
        }
        struct Platform: Decodable { let app: String; let accountLocation: String; let usesVideo: Bool; let activities: [String: Activity] }
        struct Task: Decodable { let id: String; let title: String; let status: String; let files: [String]; let acceptance: [String]; let dependsOn: [String] }
        let schemaVersion: Int; let invariants: [Invariant]; let platforms: [String: Platform]; let tasks: [Task]
    }

    static func main() async throws {
        let url = URL(fileURLWithPath: "Contracts/warmup-tasks.json")
        let contract = try JSONDecoder().decode(Contract.self, from: Data(contentsOf: url))
        try expect(contract.schemaVersion == 1, "Unknown contract schema")
        try registryParity(contract)
        try completeness(contract)
        try accountClassifierRows(contract)
        try failureClassifierRows(contract)
        try observableFailureModes(contract)
        try templateBudgets(contract)
        try await failureClassifierGates()
        try taskGraph(contract)
        print("Warm-up contract tests passed: \(contract.platforms.count) platforms, \(WarmUpScriptRegistry.definitions.count) scripts, \(contract.tasks.count) tasks")
    }

    static func registryParity(_ contract: Contract) throws {
        try expect(Set(contract.platforms.keys) == Set(WarmUpScript.Network.allCases.map(\.rawValue)), "Platforms differ from WarmUpScript.Network")
        for definition in WarmUpScriptRegistry.definitions {
            guard let activity = contract.platforms[definition.network.rawValue]?.activities[definition.activity.rawValue] else {
                throw Failure.assertion("\(definition.identifier) missing from the contract")
            }
            try expect(activity.scriptIdentifier == definition.identifier && activity.version == definition.version,
                "\(definition.identifier): identifier/version drift (contract v\(activity.version), registry v\(definition.version))")
            let engages = activity.steps.contains { $0.id == .like || $0.id == .follow } ? 1 : 0
            let script = try WarmUpScriptRegistry.script(network: definition.network, activity: definition.activity,
                itemLimit: activity.limits.itemLimit.max, duration: TimeInterval(activity.limits.maxDurationSeconds),
                likeLimit: engages, followLimit: engages)
            try expect(activity.steps.map(\.id) == script.steps.map(\.id), "\(definition.identifier): step order differs from WarmUpScript.steps")
            try expect(activity.steps.map(\.title) == script.steps.map(\.title), "\(definition.identifier): step titles differ from WarmUpScript.steps")
            try expect(activity.retryPolicy == script.retryPolicy, "\(definition.identifier): retry policy differs")
            try expect(activity.limits.itemLimit.min == 1 && activity.limits.itemLimit.max == (definition.activity == .watch ? 50 : 1),
                "\(definition.identifier): item limits differ from WarmUpScript.validate")
            let consume = activity.steps.first { $0.id == .consume }
            try expect(consume?.maximumVideoDurationSeconds == script.maximumVideoDurationSeconds,
                "\(definition.identifier): video duration limit differs (contract \(String(describing: consume?.maximumVideoDurationSeconds)), script \(String(describing: script.maximumVideoDurationSeconds)))")
        }
    }

    static func completeness(_ contract: Contract) throws {
        try expect(!contract.invariants.isEmpty && Set(contract.invariants.map(\.id)).count == contract.invariants.count, "Invariant ids repeat")
        for (name, platform) in contract.platforms {
            try expect(!platform.accountLocation.isEmpty, "\(name): no account location")
            try expect(Set(platform.activities.keys) == Set(WarmUpActivity.allCases.map(\.rawValue)), "\(name): activities differ from WarmUpActivity")
            for (kind, activity) in platform.activities {
                try expect(!activity.successCase.isEmpty, "\(name).\(kind): no success case")
                try expect(activity.steps.first?.id == .account, "\(name).\(kind): account check is not first")
                for step in activity.steps {
                    let label = "\(name).\(kind).\(step.id.rawValue)"
                    try expect(!step.successCriteria.isEmpty, "\(label): no success criteria")
                    try expect(!step.allowedActions.isEmpty, "\(label): no allowed actions")
                    try expect(!step.failureModes.isEmpty, "\(label): no failure modes")
                    try expect(step.failureModes.allSatisfy { !$0.recovery.isEmpty && !$0.detection.isEmpty }, "\(label): failure mode without detection or recovery")
                    try expect(Set(step.failureModes.map(\.id)).count == step.failureModes.count, "\(label): failure ids repeat")
                    try expect(step.budget.maxPlannerDecisions > 0 && step.budget.maxSeconds > 0, "\(label): missing budget")
                    if step.id == .submit {
                        try expect(!(step.submitControlLabels ?? []).isEmpty, "\(label): no submit control labels")
                        try expect(step.budget.maxPlannerDecisions <= 2, "\(label): submission budget allows repeated taps")
                    }
                }
            }
        }
    }

    static func accountClassifierRows(_ contract: Contract) throws {
        for (name, platform) in contract.platforms {
            guard let appPlatform = Platform.allCases.first(where: { $0.displayName == name }) else {
                throw Failure.assertion("\(name): no Platform case")
            }
            try expect(WarmUpPlaybook.accountLocation(for: appPlatform) == platform.accountLocation,
                "\(name): accountLocation differs from WarmUpPlaybook")
            for (kind, activity) in platform.activities {
                let label = "\(name).\(kind).account"
                guard let account = activity.steps.first(where: { $0.id == .account }) else {
                    throw Failure.assertion("\(label): missing from the contract")
                }
                try expect(account.successCriteria.first == platform.accountLocation,
                    "\(label): first success criterion is not the accountLocation")
                try expect(account.successCriteria.dropFirst().joined(separator: "; ") == WarmUpAccountClassifier.successCriteria,
                    "\(label): success criteria differ from WarmUpAccountClassifier.successCriteria")
                let modes = account.failureModes.map { WarmUpAccountClassifier.FailureMode(id: $0.id, detection: $0.detection) }
                for mode in WarmUpAccountClassifier.failureModes {
                    try expect(modes.first(where: { $0.id == mode.id }) == mode,
                        "\(label): failure mode \(mode.id) detection differs from WarmUpAccountClassifier")
                }
                let options = try WarmUpAccountClassifier.options(failureModes: modes)
                try expect(options.count >= 2 && options.count <= 16, "\(label): option count out of Semif range")
                try expect(Set(options.map(\.id)).count == options.count, "\(label): option ids repeat")
                try expect(options.map(\.id) == WarmUpAccountClassifier.optionIDs, "\(label): option order drifted")
                let row = try WarmUpAccountClassifier.row(platform: name, accountLocation: platform.accountLocation,
                    handle: "persona", ocrText: ["@persona"], failureModes: modes)
                try SemanticIfPrompt.validate(row.decision)
            }
        }
    }

    static func failureClassifierRows(_ contract: Contract) throws {
        var stepCount = 0
        var modeCount = 0
        for (name, platform) in contract.platforms {
            for (kind, activity) in platform.activities {
                for step in activity.steps where step.id != .account {
                    let label = "\(name).\(kind).\(step.id.rawValue)"
                    let stepContract = WarmUpStepContract(id: step.id.rawValue, title: step.title,
                        successCriteria: step.successCriteria,
                        failureModes: step.failureModes.map {
                            .init(id: $0.id, detection: $0.detection, recovery: $0.recovery, terminal: $0.terminal ?? false,
                                  observable: $0.observable ?? false, visible: $0.visible ?? "", ocrRule: $0.ocrRule)
                        },
                        budget: WarmUpStepBudget(maxPlannerDecisions: step.budget.maxPlannerDecisions,
                            maxSeconds: step.budget.maxSeconds))
                    let observable = step.failureModes.filter { $0.observable == true && $0.terminal != true }
                    let options = WarmUpFailureClassifier.options(step: stepContract)
                    try expect(options.count <= 16, "\(label): option count out of Semif range")
                    try expect(Set(options.map(\.id)).count == options.count, "\(label): option ids repeat")
                    try expect(options.map(\.id) == ["none"] + observable.map(\.id),
                        "\(label): option set is not none + observable, non-terminal failureModes in contract order")
                    try expect(zip(options.dropFirst(), observable).allSatisfy { $0.0.description == $0.1.visible },
                        "\(label): option descriptions differ from the contract visible text")
                    try expect(WarmUpFailureClassifier.options(step: stepContract, ocrText: []).map(\.id)
                        == ["none"] + observable.filter { $0.ocrRule == nil }.map(\.id), "\(label): OCR rules did not gate their modes")
                    var row = WarmUpFailureClassifier.row(scriptIdentifier: activity.scriptIdentifier,
                        platform: name, step: stepContract, screenState: "foregroundApp",
                        playbackSummary: nil, ocrText: ["fixture"])
                    try expect(row.question == WarmUpFailureClassifier.question,
                        "\(label): missing failure classification instruction")
                    guard case .object(let state) = row.state else { throw Failure.assertion("Malformed failure state") }
                    try expect(state.map(\.0) == ["platform", "step", "screenState", "playbackEvidence", "ocrText"],
                        "\(label): failure evidence must hold only screen facts, never the success criteria")
                    row.options = options
                    if options.count >= 2 { try SemanticIfPrompt.validate(row.decision) }
                    for mode in step.failureModes {
                        try expect((1...2).contains(WarmUpFailureClassifier.attemptLimit(for: mode.id)),
                            "\(label): unbounded recovery for \(mode.id)")
                        modeCount += 1
                    }
                    stepCount += 1
                }
            }
        }
        var accountStepCount = 0
        var accountModeCount = 0
        for platform in contract.platforms.values {
            for activity in platform.activities.values {
                if let account = activity.steps.first(where: { $0.id == .account }) {
                    accountStepCount += 1
                    accountModeCount += account.failureModes.count
                }
            }
        }
        let store = try WarmUpContractStore(data: Data(contentsOf: URL(fileURLWithPath: "Contracts/warmup-tasks.json")))
        try expect(store.stepCount == stepCount + accountStepCount, "Store step count differs from the contract")
        try expect(store.failureModeCount == modeCount + accountModeCount, "Store failure-mode count differs from the contract")
        for definition in WarmUpScriptRegistry.definitions {
            let script = try WarmUpScriptRegistry.script(network: definition.network, activity: definition.activity,
                itemLimit: 1, duration: 300)
            for step in script.steps {
                let found = store.step(scriptIdentifier: definition.identifier, stepID: step.id.rawValue)
                try expect(found != nil, "\(definition.identifier).\(step.id.rawValue): missing from the decoded store")
                try expect(found?.budget.maxPlannerDecisions ?? 0 > 0 && found?.budget.maxSeconds ?? 0 > 0,
                    "\(definition.identifier).\(step.id.rawValue): store lost the budget")
            }
        }
    }

    /// Modes decided from runner state or the structured observation, never offered to Laya.
    static let runnerOwned: Set = ["keyboard-locale", "query-too-long", "search-not-focused", "no-qualifying-result",
        "threshold-unreadable", "stalled-wait-loop", "too-long", "same-item", "already-liked", "like-unverified",
        "already-following", "follow-unverified", "duplicate-tap", "unlabeled-control", "unconfirmed", "media-not-found",
        "wrong-target", "paused", "navigated-away"]

    static func observableFailureModes(_ contract: Contract) throws {
        var offered = 0
        for (name, platform) in contract.platforms {
            for (kind, activity) in platform.activities {
                for step in activity.steps {
                    for mode in step.failureModes {
                        let label = "\(name).\(kind).\(step.id.rawValue).\(mode.id)"
                        guard let observable = mode.observable else { throw Failure.assertion("\(label): observable is not declared") }
                        try expect(!observable || step.id != .account, "\(label): the account step is classified by WarmUpAccountClassifier")
                        try expect(!observable || !runnerOwned.contains(mode.id), "\(label): a runner-owned mode is offered to Laya")
                        try expect(observable == !(mode.visible ?? "").isEmpty, "\(label): visible text must exist exactly for observable modes")
                        try expect(!observable || mode.terminal != true || mode.ocrRule != nil,
                            "\(label): a terminal observable mode needs an OCR rule before it can stop a run")
                        if let rule = mode.ocrRule {
                            try expect(observable && (try? NSRegularExpression(pattern: rule)) != nil, "\(label): ocrRule does not compile")
                        }
                        if observable { offered += 1 }
                    }
                }
            }
        }
        try expect(offered > 0, "No failure mode is observable")
        let x = contract.platforms["X"]?.activities.values.flatMap(\.steps).filter { $0.id == .consume }
            .flatMap(\.failureModes).filter { $0.id == "navigated-away" } ?? []
        try expect(!x.isEmpty && x.allSatisfy { $0.detection == "screen.state != foregroundApp" },
            "X consume has no player chrome; navigated-away must be read from the screen state")
    }

    final class StubScorer: SemanticIfScoring, @unchecked Sendable {
        let winner: String
        private(set) var rows: [SemanticIfRow] = []
        init(winner: String) { self.winner = winner }
        func score(_ row: SemanticIfRow) async throws -> SemanticIfResult {
            rows.append(row)
            let probabilities = Dictionary(uniqueKeysWithValues: row.options.map { ($0.id, $0.id == winner ? 0.9 : 0.1 / Double(row.options.count - 1)) })
            return SemanticIfResult(score: SemanticIfScore(rowID: row.id, probabilities: probabilities, argmaxOptionID: winner, margin: 0.8,
                optionLogits: [], inputTokens: 0, forwardSeconds: 0, totalSeconds: 0, promptHash: "stub", peakMemoryBytes: 0))
        }
    }

    static func failureClassifierGates() async throws {
        let store = try WarmUpContractStore(data: Data(contentsOf: URL(fileURLWithPath: "Contracts/warmup-tasks.json")))
        guard let verify = store.step(scriptIdentifier: "warmup.tiktok.comment", stepID: "verifySubmission"),
              let search = store.step(scriptIdentifier: "warmup.x.watch", stepID: "search") else { throw Failure.assertion("Missing steps") }
        func regions(_ lines: [String], confidence: Float = 0.95) -> [PhoneSubmissionGuard.TextRegion] {
            lines.enumerated().map { .init(text: $1, confidence: confidence, bounds: CGRect(x: 0.05, y: 0.1 + 0.8 * Double($0) / Double(max(lines.count, 1)), width: 0.8, height: 0.01)) }
        }
        func classify(_ step: WarmUpStepContract, _ lines: [String], winner: String, confidence: Float = 0.95,
                      screen: String = "foregroundApp") async throws -> (WarmUpFailureDecision, StubScorer) {
            let scorer = StubScorer(winner: winner)
            let decision = try await WarmUpFailureClassifier.classify(regions: regions(lines, confidence: confidence), scriptIdentifier: "warmup.tiktok.comment",
                platform: "TikTok", step: step, playbackSummary: nil, screenState: screen, scorer: scorer)
            return (decision, scorer)
        }
        let posted = ["313 comments", "toptopnonstop99", "Clean breakdown of the entry and stop", "Just now", "marketmike", "Try again next week lol", "Add comment..."]
        let (quiet, idle) = try await classify(verify, posted, winner: "error-banner")
        try expect(idle.rows.isEmpty && quiet.failureModeID == nil && !quiet.terminal, "A posted comment that mentions trying again reached Laya")
        let (typed, unused) = try await classify(search, ["latte art", "Cancel", "q", "w", "e"], winner: "search-not-focused")
        try expect(unused.rows.isEmpty && typed.failureModeID == nil, "Runner-owned search modes were offered to Laya")
        let error = ["312 comments", "Couldn’t post comment. Try again.", "Clean breakdown of the entry and stop", "Add comment..."]
        let (banner, scorer) = try await classify(verify, error, winner: "none", screen: "dialog")
        try expect(scorer.rows.isEmpty && banner.failureModeID == "error-banner" && banner.terminal,
            "A matching error alert was not a terminal mode decided without Laya")
        let (blurry, ignored) = try await classify(verify, error, winner: "error-banner", confidence: 0.5)
        try expect(ignored.rows.isEmpty && !blurry.terminal, "Low-confidence OCR stopped a run")
        let unruled = WarmUpStepContract(id: "verifySubmission", title: "Verify", successCriteria: [], failureModes: [
            .init(id: "error-banner", detection: "", recovery: "", terminal: true, observable: true, visible: "An error.")],
            budget: .init(maxPlannerDecisions: 1, maxSeconds: 1))
        let (guessed, unscored) = try await classify(unruled, error, winner: "error-banner")
        try expect(unscored.rows.isEmpty && guessed.failureModeID == nil && !guessed.terminal, "A terminal mode stopped without its OCR rule")
        func placed(_ rows: [(String, Double)]) -> [PhoneSubmissionGuard.TextRegion] {
            rows.map { .init(text: $0.0, confidence: 0.95, bounds: CGRect(x: 0.05, y: $0.1, width: 0.6, height: 0.016)) }
        }
        func decide(_ step: WarmUpStepContract, _ rows: [(String, Double)], platform: String = "TikTok") async throws -> (WarmUpFailureDecision, StubScorer) {
            let scorer = StubScorer(winner: "none")
            let decision = try await WarmUpFailureClassifier.classify(regions: placed(rows), scriptIdentifier: "fixture", platform: platform,
                step: step, playbackSummary: nil, scorer: scorer)
            return (decision, scorer)
        }
        let (comments, unasked) = try await decide(verify, [("312 comments", 0.3), ("marketmike", 0.45), ("Something went wrong with my broker today lol", 0.48),
            ("dayone", 0.52), ("Try again!", 0.55), ("Could not post a screenshot here, chart too big", 0.6), ("Add comment...", 0.93)])
        try expect(unasked.rows.isEmpty && comments.failureModeID == nil && !comments.terminal, "Other people's comments stopped a posted comment as an error")
        let (toast, _) = try await decide(verify, [("Couldn't post comment. Tap to retry.", 0.1), ("312 comments", 0.3), ("Add comment...", 0.93)])
        try expect(toast.failureModeID == "error-banner" && toast.terminal, "An app error toast did not stop the run")
        guard let youtube = store.step(scriptIdentifier: "warmup.youtube.comment", stepID: "open"),
              let x = store.step(scriptIdentifier: "warmup.x.comment", stepID: "open") else { throw Failure.assertion("Missing open steps") }
        let (channelCard, results) = try await decide(youtube, [("latte art", 0.066), ("All", 0.115), ("Shorts", 0.115), ("Videos", 0.115),
            ("Swing Trading Academy", 0.2), ("1.2M subscribers", 0.23)], platform: "YouTube")
        try expect(results.rows.isEmpty && channelCard.failureModeID == nil, "A channel card in search results was offered as an opened account")
        let (people, posts) = try await decide(x, [("Top", 0.112), ("Latest", 0.112), ("People", 0.112), ("Cafe Luna", 0.16), ("Follow", 0.16),
            ("Jane Doe @janedoe · 2h", 0.3), ("Poured my first rosetta today", 0.33)], platform: "X")
        try expect(posts.rows.allSatisfy { !$0.options.contains { $0.id == "account-only-results" } } && people.failureModeID == nil,
            "A People module above posts was offered as account-only results")
        let (_, accounts) = try await decide(x, [("Top", 0.112), ("Latest", 0.112), ("People", 0.112), ("Cafe Luna", 0.16), ("Follow", 0.16),
            ("@cafeluna", 0.18)], platform: "X")
        try expect(accounts.rows.first?.options.contains { $0.id == "account-only-results" } == true, "Account-only results were no longer offered")
        guard let open = store.step(scriptIdentifier: "warmup.tiktok.comment", stepID: "open") else { throw Failure.assertion("Missing open step") }
        let noisy = (0..<200).map { "8,410 · 3.4M · 12:41 · 🔥🔥 #fyp line \($0)" } + ["Sponsored"]
        let (_, capped) = try await classify(open, noisy, winner: "none")
        guard case .object(let fields) = capped.rows.first?.state, case .array(let ocr)? = fields.first(where: { $0.0 == "ocrText" })?.1 else {
            throw Failure.assertion("Capped OCR was not scored")
        }
        let text = ocr.compactMap { if case .string(let line) = $0 { line } else { nil } }
        try expect(text.count <= WarmUpFailureClassifier.maximumOCRLines && text.reduce(0) { $0 + $1.utf8.count } <= WarmUpFailureClassifier.maximumOCRBytes
            && text.last == noisy.last && text.first == noisy.first, "OCR evidence exceeded Laya's input or dropped the matching line")
    }

    /// Every watch step's budget covers the shortest route to $done through its bundled template, once that template exists.
    static func templateBudgets(_ contract: Contract) throws {
        for network in WarmUpScript.Network.allCases {
            let url = URL(fileURLWithPath: "Contracts/\(PhoneTransactionCompiler.watchTemplateName(for: network)).json")
            guard let template = try? Data(contentsOf: url) else { continue }
            let engages = network == .tikTok ? 1 : 0
            let script = try WarmUpScriptRegistry.script(network: network, activity: .watch, itemLimit: 1, duration: 300,
                likeLimit: engages, followLimit: engages)
            let plan = try PhoneTransactionCompiler.watch(script: script, query: "latte art", template: template)
            try expect(plan.phases.map(\.id) == script.steps.map(\.id.rawValue), "\(network.rawValue): template phases differ from the script steps")
            for phase in plan.phases {
                let label = "\(network.rawValue).watch.\(phase.id)"
                guard let budget = contract.platforms[network.rawValue]?.activities["watch"]?.steps
                    .first(where: { $0.id.rawValue == phase.id })?.budget else { throw Failure.assertion("\(label): no budget") }
                guard let visits = minimalVisits(phase) else { throw Failure.assertion("\(label): $done is unreachable") }
                try expect(budget.maxPlannerDecisions >= visits,
                    "\(label): budget \(budget.maxPlannerDecisions) is below the \(visits)-visit happy path")
                try expect(budget.maxSeconds >= 5 * visits, "\(label): \(budget.maxSeconds) s cannot fit \(visits) observer calls")
                let perDecision = phase.id == "consume" ? 10 : 15
                try expect(budget.maxSeconds >= perDecision * budget.maxPlannerDecisions,
                    "\(label): \(budget.maxSeconds) s cannot fit \(budget.maxPlannerDecisions) decisions at live observer latency (12 s median, 17 s p90)")
            }
        }
    }

    /// Fewest runner visits from the entry to $done: one per observation, plus one to verify each command.
    static func minimalVisits(_ phase: PhoneTransactionPlan.Phase) -> Int? {
        var best = [phase.entry: 0]
        var open: Set = [phase.entry]
        var done: Int?
        while let id = open.min(by: { best[$0]! < best[$1]! }) {
            open.remove(id)
            for branch in phase.states.first(where: { $0.id == id })?.branches ?? [] {
                let cost = best[id]! + (branch.command == nil ? 1 : 2)
                if branch.next == "$done" { done = min(done ?? cost, cost) }
                else if branch.next != "$stop", cost < best[branch.next] ?? .max {
                    best[branch.next] = cost
                    open.insert(branch.next)
                }
            }
        }
        return done
    }

    static func taskGraph(_ contract: Contract) throws {
        let ids = contract.tasks.map(\.id)
        try expect(Set(ids).count == ids.count, "Task ids repeat")
        for task in contract.tasks {
            try expect(["todo", "in-progress", "done"].contains(task.status), "\(task.id): unknown status \(task.status)")
            try expect(!task.files.isEmpty && !task.acceptance.isEmpty, "\(task.id): no files or acceptance")
            try expect(task.dependsOn.allSatisfy { ids.contains($0) && $0 != task.id }, "\(task.id): dependsOn does not resolve")
        }
        try expect(contract.tasks.contains { $0.status == "done" && $0.files.contains("Tests/WarmUpTasksContractTests.swift") }, "This test is not recorded as done")
    }
}
