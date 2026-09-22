import Foundation

// From apple/: swiftc -swift-version 6 ShortReel/Models/*.swift ShortReel/Services/DeviceHost.swift ShortReel/Services/DevicePrompts/{WarmUpScript,WarmUpPlaybook,DeviceWorkflow,DevicePromptPlan,DevicePromptPlanner,PhoneVisionTypes,PhoneSubmissionGuard,WarmUpAccountClassifier}.swift SemanticIf/Sources/SemanticIf/{SemanticIfPrompt,SemanticIfScoring}.swift Tests/WarmUpTasksContractTests.swift -o /tmp/shortreel-contract-tests && /tmp/shortreel-contract-tests
/// Contracts/warmup-tasks.json is state, not documentation: it must match the
/// Swift registry exactly and describe a success case and recoveries for every
/// step of every platform × activity.
@main
enum WarmUpTasksContractTests {
    enum Failure: Error { case assertion(String) }
    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw Failure.assertion(message) }
    }

    struct Contract: Decodable {
        struct Invariant: Decodable { let id: String; let rule: String; let enforcedBy: String }
        struct FailureMode: Decodable { let id: String; let detection: String; let recovery: String }
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

    static func main() throws {
        let url = URL(fileURLWithPath: "Contracts/warmup-tasks.json")
        let contract = try JSONDecoder().decode(Contract.self, from: Data(contentsOf: url))
        try expect(contract.schemaVersion == 1, "Unknown contract schema")
        try registryParity(contract)
        try completeness(contract)
        try accountClassifierRows(contract)
        try taskGraph(contract)
        print("Warm-up contract tests passed: \(contract.platforms.count) platforms, \(WarmUpScriptRegistry.definitions.count) scripts, \(contract.tasks.count) tasks")
    }

    /// Identifiers, versions, step order, titles, limits and retry policy come
    /// from the Swift model; the JSON may add detail but never disagree.
    static func registryParity(_ contract: Contract) throws {
        try expect(Set(contract.platforms.keys) == Set(WarmUpScript.Network.allCases.map(\.rawValue)), "Platforms differ from WarmUpScript.Network")
        for definition in WarmUpScriptRegistry.definitions {
            guard let activity = contract.platforms[definition.network.rawValue]?.activities[definition.activity.rawValue] else {
                throw Failure.assertion("\(definition.identifier) missing from the contract")
            }
            try expect(activity.scriptIdentifier == definition.identifier && activity.version == definition.version,
                "\(definition.identifier): identifier/version drift (contract v\(activity.version), registry v\(definition.version))")
            let script = try WarmUpScriptRegistry.script(network: definition.network, activity: definition.activity,
                itemLimit: activity.limits.itemLimit.max, duration: TimeInterval(activity.limits.maxDurationSeconds))
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

    /// Every step of every script carries a success case and at least one
    /// failure mode with a recovery; submissions name their control labels.
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

    /// TASK-8 (#15): every account step's failureModes build the classifier's
    /// decision row — a valid Semif row with ≤16 unique options, the contract's
    /// detection text as descriptions — and the Swift copies of the success
    /// criteria and accountLocation match this file verbatim.
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
