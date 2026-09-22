import Foundation
import CoreGraphics
import ImageIO

// swiftc -swift-version 6 SemanticIf/Sources/SemanticIf/{SemanticIfPrompt,SemanticIfScoring}.swift ShortReel/Services/DevicePrompts/{WarmUpScript,PhonePlaybackTracker,PhoneSubmissionGuard,PhoneSubmissionCheckpoint,DevicePromptPlan,DevicePromptPlanner,DeviceWorkflow,PhoneVisionTypes,PhoneVisualRunner,WarmUpStateTree,WarmUpAccountClassifier,WarmUpFailureClassifier}.swift Tests/PhoneVisualRunnerTests.swift -o /tmp/shortreel-visual-runner-tests
@main @MainActor
enum PhoneVisualRunnerTests {
    private enum TestError: LocalizedError {
        case failed(String)
        var errorDescription: String? {
            switch self { case .failed(let message): message }
        }
    }

    @MainActor private final class Gate {
        private(set) var waiting = false
        private var continuation: CheckedContinuation<Void, Never>?

        func wait() async {
            waiting = true
            await withCheckedContinuation { continuation = $0 }
        }

        func release() {
            continuation?.resume()
            continuation = nil
        }
    }

    static func main() async throws {
        try await observationOrderAndVerification()
        try await rejectUnfreshFrames()
        try await rejectChangedSourceAndDuplicateID()
        try await rejectMalformedImages()
        try await stopRepeatedInput()
        try await rejectMalformedDecisions()
        try await retryNamesTheRejection()
        try await requireClarification()
        try await disconnectBeforeDispatch()
        try await cancelledModelCannotDispatch()
        try await cancellationStopsRemainingInput()
        try await decisionAndDurationLimits()
        try await failedInputStopsLoop()
        try await stopNearlyIdenticalTapLoop()
        try await appSwitcherDiagnostic()
        try await tiktokPlaybackReview()
        try await scriptedWatchLoop()
        try await scriptedLongVideoSkip()
        try await stateTreeBypassesModel()
        try await stateTreeDisconnectBlocksInput()
        try await scriptDeadline()
        try await submissionJournalPrecedesInput()
        try await submissionStorageFailureBlocksInput()
        try await submissionCannotBeRepeatedDuringVerification()
        try await accountMatchFinishesStepWithoutPlannerClaim()
        try await accountMismatchSendsNoInput()
        try await accountSignedOutSendsNoInput()
        try await accountUnreadableRecoveryThenNeedsInput()
        try await accountCheckUnavailableKeepsPlannerPath()
        try await accountCheckTikTokStateTreeInterplay()
        let failureModes = try await failureModeRecoveryBranches()
        try await failureCheckUncertainKeepsPlannerPath()
        try await failureCheckUnavailableKeepsPlannerPath()
        try await stepDecisionBudgetSendsNoInputPastLimit()
        try await stepTimeBudgetSendsNoInputPastLimit()
        print("Phone visual runner tests passed (35 scenarios, \(failureModes) contract failure modes)")
    }

    // MARK: - Account-step classifier (contract TASK-8, issue #15)

    struct AccountFixture: Decodable {
        struct Region: Decodable {
            let text: String
            let confidence: Float
            let x: Double, y: Double, width: Double, height: Double
        }
        let platform: String
        let handle: String
        let outcome: String
        let regions: [Region]

        static func load(_ name: String) throws -> AccountFixture {
            try JSONDecoder().decode(AccountFixture.self,
                from: Data(contentsOf: URL(fileURLWithPath: "Tests/Fixtures/AccountOCR/\(name).json")))
        }

        var textRegions: [PhoneSubmissionGuard.TextRegion] {
            regions.map {
                PhoneSubmissionGuard.TextRegion(text: $0.text, confidence: $0.confidence,
                    bounds: CGRect(x: $0.x, y: $0.y, width: $0.width, height: $0.height))
            }
        }
    }

    /// Scripted `SemanticIfScoring`: the winner takes 0.7, the rest share 0.3,
    /// so the margin policy decides `.option(winner)`.
    final class AccountStubScorer: SemanticIfScoring, @unchecked Sendable {
        let winner: String
        init(winner: String) { self.winner = winner }

        func score(_ row: SemanticIfRow) async throws -> SemanticIfResult {
            var probabilities = [winner: 0.7]
            for id in row.options.map(\.id) where id != winner { probabilities[id] = 0.1 }
            return SemanticIfResult(score: SemanticIfScore(
                rowID: row.id, probabilities: probabilities, argmaxOptionID: winner,
                margin: 0.6, optionLogits: [], inputTokens: 0, forwardSeconds: 0,
                totalSeconds: 0, promptHash: "stub-\(winner)", peakMemoryBytes: 0))
        }
    }

    private static func accountClassifier(
        fixture: AccountFixture
    ) -> (PhoneScreenFrame, WarmUpScript, String) async throws -> WarmUpAccountDecision? {
        { _, _, _ in
            try await WarmUpAccountClassifier.classify(regions: fixture.textRegions,
                platform: fixture.platform, accountLocation: "test account location",
                handle: fixture.handle, scorer: AccountStubScorer(winner: fixture.outcome == "signed-out" ? "signed-out" : "profile"))
        }
    }

    /// A local `matches` verdict finishes the account step on its own: the
    /// planner is only asked about the next step, and no input is sent.
    private static func accountMatchFinishesStepWithoutPlannerClaim() async throws {
        let fixture = try AccountFixture.load("x-matches")
        var decideGoals: [String] = []
        var inputs: [PhonePromptAction] = []
        var accountSteps: [PhoneVisionStep] = []
        let runner = PhoneVisualRunner(capture: { after in try frame(after: after) },
            decide: { goal, _, _ in
                decideGoals.append(goal)
                return .needsInput("Stopping after the account check.")
            }, perform: { inputs.append($0) }, blockedReason: { nil },
            classifyAccount: accountClassifier(fixture: fixture))
        do {
            _ = try await runner.run(goal: "Account check: Verify exactly @janedoe, ignoring case.",
                workflow: .warmUp, warmUpScript: WarmUpScript(network: .x, activity: .post, itemLimit: 1, duration: 30),
                onProgress: { _ in }, onStep: { if $0.accountCheck != nil { accountSteps.append($0) } })
            throw TestError.failed("Run continued past the stop marker")
        } catch is PhonePromptPlanningError { }
        try expect(decideGoals.count == 1 && decideGoals[0].contains("Prepare post"),
            "The planner was asked to decide the account step")
        try expect(inputs.isEmpty, "A verified account check sent input")
        try expect(accountSteps.count == 1 && accountSteps[0].decisionSource == "Laya Core ML"
            && accountSteps[0].accountCheck?.outcome == .matches
            && accountSteps[0].accountCheck?.promptHash == "stub-profile"
            && accountSteps[0].accountCheck?.margin == 0.6,
            "The local account decision was not journaled with the step")
    }

    /// HARD SAFETY: a local mismatch verdict is terminal needsInput before the
    /// planner is even asked — zero engagement input can be sent.
    private static func accountMismatchSendsNoInput() async throws {
        let fixture = try AccountFixture.load("x-mismatch")
        var decideCalls = 0
        var inputs: [PhonePromptAction] = []
        var accountSteps: [PhoneVisionStep] = []
        let runner = PhoneVisualRunner(capture: { after in try frame(after: after) },
            decide: { _, _, _ in
                decideCalls += 1
                return .action(.tap(0.5, 0.5), reason: "Follow the visible account")
            }, perform: { inputs.append($0) }, blockedReason: { nil },
            classifyAccount: accountClassifier(fixture: fixture))
        do {
            _ = try await runner.run(goal: "Account check: Verify exactly @janedoe, ignoring case.",
                workflow: .warmUp, warmUpScript: WarmUpScript(network: .x, activity: .post, itemLimit: 1, duration: 30),
                onProgress: { _ in }, onStep: { if $0.accountCheck != nil { accountSteps.append($0) } })
            throw TestError.failed("A mismatched account ran the warm-up")
        } catch let error as PhonePromptPlanningError {
            try expect(error.localizedDescription.contains("@jane.doe88")
                && error.localizedDescription.contains("@janedoe"),
                "Mismatch did not name both handles")
        }
        try expect(decideCalls == 0 && inputs.isEmpty, "A mismatched account engaged the phone")
        try expect(accountSteps.count == 1 && accountSteps[0].accountCheck?.outcome == .mismatch,
            "The terminal mismatch was not journaled")
    }

    /// HARD SAFETY: a signed-out verdict is terminal needsInput with no input.
    private static func accountSignedOutSendsNoInput() async throws {
        let fixture = try AccountFixture.load("x-signed-out")
        var decideCalls = 0
        var inputs: [PhonePromptAction] = []
        let runner = PhoneVisualRunner(capture: { after in try frame(after: after) },
            decide: { _, _, _ in
                decideCalls += 1
                return .action(.typeText("password"), reason: "Sign in")
            }, perform: { inputs.append($0) }, blockedReason: { nil },
            classifyAccount: accountClassifier(fixture: fixture))
        do {
            _ = try await runner.run(goal: "Account check: Verify exactly @janedoe, ignoring case.",
                workflow: .warmUp, warmUpScript: WarmUpScript(network: .x, activity: .post, itemLimit: 1, duration: 30),
                onProgress: { _ in }, onStep: { _ in })
            throw TestError.failed("A signed-out app ran the warm-up")
        } catch let error as PhonePromptPlanningError {
            try expect(error.localizedDescription.contains("signed out"),
                "Signed-out verdict did not explain itself")
        }
        try expect(decideCalls == 0 && inputs.isEmpty, "A signed-out app received credentials or engagement")
    }

    /// Unreadable verdicts never trust a planner finish claim; the contract's
    /// recovery fires once (one Home + reopen), then needsInput.
    private static func accountUnreadableRecoveryThenNeedsInput() async throws {
        let fixture = try AccountFixture.load("x-unreadable")
        var captures = 0
        var decideCalls = 0
        var inputs: [PhonePromptAction] = []
        let runner = PhoneVisualRunner(capture: { after in
                captures += 1
                // Alternate visibly distinct screens so the stalled-input
                // guard measures the waits, not JPEG-identical frames.
                return try frame(after: after, shade: captures.isMultiple(of: 2) ? 0 : 0.5)
            }, decide: { _, _, _ in
                decideCalls += 1
                // A planner claim is not proof while the local check is unreadable.
                return .finished("I can see the handle clearly.")
            }, perform: { inputs.append($0) }, blockedReason: { nil },
            classifyAccount: accountClassifier(fixture: fixture))
        do {
            _ = try await runner.run(goal: "Account check: Verify exactly @janedoe, ignoring case.",
                workflow: .warmUp, warmUpScript: WarmUpScript(network: .x, activity: .post, itemLimit: 1, duration: 30),
                onProgress: { _ in }, onStep: { _ in })
            throw TestError.failed("An unreadable account was verified by a planner claim")
        } catch let error as PhonePromptPlanningError {
            try expect(error.localizedDescription.contains("after reopening the app once"),
                "Unreadable did not end in the contract's recovery outcome")
        }
        // Two unreadable windows of three fresh frames each: the planner was
        // consulted only for navigation, the recovery sent exactly one Home,
        // and no engagement input ever fired.
        try expect(decideCalls == 4, "Planner finish claims were accepted while unreadable")
        try expect(inputs == [.home], "The unreadable recovery sent more than one Home")
    }

    /// No loaded scorer (disabled or failed) is exactly today's planner-only
    /// path: the planner's own finish claim advances the account step.
    private static func accountCheckUnavailableKeepsPlannerPath() async throws {
        var decideCalls = 0
        var accountSteps: [PhoneVisionStep] = []
        let runner = PhoneVisualRunner(capture: { after in try frame(after: after) },
            decide: { _, _, _ in
                decideCalls += 1
                return decideCalls == 1
                    ? .finished("Planner-verified account")
                    : .needsInput("Stopping after the account check.")
            }, perform: { _ in throw TestError.failed("Unexpected input") }, blockedReason: { nil },
            classifyAccount: { _, _, _ in nil })
        do {
            _ = try await runner.run(goal: "Account check: Verify exactly @janedoe, ignoring case.",
                workflow: .warmUp, warmUpScript: WarmUpScript(network: .x, activity: .post, itemLimit: 1, duration: 30),
                onProgress: { _ in }, onStep: { if $0.action.hasPrefix("Verified") { accountSteps.append($0) } })
            throw TestError.failed("Run continued past the stop marker")
        } catch is PhonePromptPlanningError { }
        try expect(decideCalls == 2, "Planner-only path lost the account decision")
        try expect(accountSteps.count == 1 && accountSteps[0].accountCheck == nil,
            "Planner-only path recorded a local account decision")
    }

    /// With the TikTok state tree active, the local verdict still owns the
    /// account step's finish; the tree and planner handle the later steps.
    private static func accountCheckTikTokStateTreeInterplay() async throws {
        let fixture = try AccountFixture.load("tiktok-matches")
        var decideTitles: [String] = []
        var inputs: [PhonePromptAction] = []
        var accountSteps: [PhoneVisionStep] = []
        let runner = PhoneVisualRunner(capture: { after in try frame(after: after) },
            decide: { goal, _, _ in
                for title in ["Search niche", "Choose search result", "Find video with >10K hearts", "Watch to completion"] {
                    if goal.contains(": \(title).") { decideTitles.append(title) }
                }
                return .finished("Current milestone verified from the screenshot")
            }, perform: { inputs.append($0) }, blockedReason: { nil },
            readText: { frame, platform in
                .init(sourceID: frame.sourceID, capturedAt: frame.capturedAt, platform: platform, regions: [])
            }, classifyAccount: accountClassifier(fixture: fixture))
        let result = try await runner.run(
            goal: "Platform: TikTok\nAccount check: Verify exactly @janedoe, ignoring case.",
            workflow: .warmUp, warmUpScript: WarmUpScript(network: .tikTok, activity: .watch, itemLimit: 1, duration: 60),
            onProgress: { _ in }, onStep: { if $0.accountCheck != nil { accountSteps.append($0) } })
        try expect(result.contains("completed"), "Script did not complete after the local account check")
        try expect(decideTitles == ["Search niche", "Choose search result", "Find video with >10K hearts", "Watch to completion"],
            "The planner decided the account step or skipped a later step")
        try expect(inputs.isEmpty, "The classified account run sent input")
        try expect(accountSteps.count == 1 && accountSteps[0].accountCheck?.outcome == .matches,
            "The TikTok account step was not decided locally")
    }

    // MARK: - Per-step failure-mode classifier (contract TASK-5/6, issue #16)

    /// The contract JSON, decoded for the parameterized failure-mode loop.
    struct WarmUpContractFixture: Decodable {
        struct FailureMode: Decodable { let id: String; let detection: String; let recovery: String; let terminal: Bool? }
        struct Budget: Decodable { let maxPlannerDecisions: Int; let maxSeconds: Int }
        struct Step: Decodable {
            let id: String; let title: String; let successCriteria: [String]
            let failureModes: [FailureMode]; let budget: Budget
        }
        struct Activity: Decodable { let scriptIdentifier: String; let steps: [Step] }
        struct Platform: Decodable { let activities: [String: Activity] }
        let platforms: [String: Platform]

        static func load() throws -> WarmUpContractFixture {
            try JSONDecoder().decode(WarmUpContractFixture.self,
                from: Data(contentsOf: URL(fileURLWithPath: "Contracts/warmup-tasks.json")))
        }
    }

    /// Scripted `SemanticIfScoring` with a tunable margin: above the default
    /// threshold the winner is decided, below it the verdict is `.uncertain`.
    final class FailureStubScorer: SemanticIfScoring, @unchecked Sendable {
        let winner: String
        let margin: Double
        init(winner: String, margin: Double = 0.6) { self.winner = winner; self.margin = margin }

        func score(_ row: SemanticIfRow) async throws -> SemanticIfResult {
            var probabilities = [winner: 0.7]
            for id in row.options.map(\.id) where id != winner { probabilities[id] = 0.1 }
            return SemanticIfResult(score: SemanticIfScore(
                rowID: row.id, probabilities: probabilities, argmaxOptionID: winner,
                margin: margin, optionLogits: [], inputTokens: 0, forwardSeconds: 0,
                totalSeconds: 0, promptHash: "stub-\(winner)", peakMemoryBytes: 0))
        }
    }

    /// One runner scenario per failureMode.id in warmup-tasks.json (every
    /// non-account step of every platform × activity; the account step's modes
    /// are covered by the TASK-8 scenarios above). Each asserts the mode's one
    /// recovery branch: terminal modes end in needsInput naming the step and
    /// mode with no input past detection; runner-owned branches send exactly
    /// the canonical input; directive branches reach the planner carrying the
    /// contract's detection and recovery text.
    @discardableResult
    private static func failureModeRecoveryBranches() async throws -> Int {
        let contract = try WarmUpContractFixture.load()
        var checked = 0
        for (platformName, platform) in contract.platforms {
            guard let network = WarmUpScript.Network(rawValue: platformName) else {
                throw TestError.failed("Unknown contract platform \(platformName)")
            }
            for (activityName, activity) in platform.activities {
                guard let activityKind = WarmUpActivity(rawValue: activityName) else {
                    throw TestError.failed("Unknown contract activity \(activityName)")
                }
                for step in activity.steps where step.id != "account" {
                    for mode in step.failureModes {
                        try await assertFailureModeRecovery(network: network, activity: activityKind,
                            scriptIdentifier: activity.scriptIdentifier, step: step, mode: mode)
                        checked += 1
                    }
                }
            }
        }
        try expect(checked >= 100, "Only \(checked) contract failure modes were checked")
        return checked
    }

    private static func assertFailureModeRecovery(network: WarmUpScript.Network, activity: WarmUpActivity,
        scriptIdentifier: String, step: WarmUpContractFixture.Step, mode: WarmUpContractFixture.FailureMode
    ) async throws {
        let label = "\(scriptIdentifier).\(step.id).\(mode.id)"
        let terminal = mode.terminal ?? false
        guard let targetStepID = WarmUpScript.StepID(rawValue: step.id) else {
            throw TestError.failed("\(label): unknown step id")
        }
        let stepContract = WarmUpStepContract(id: step.id, title: step.title, successCriteria: step.successCriteria,
            failureModes: step.failureModes.map {
                .init(id: $0.id, detection: $0.detection, recovery: $0.recovery, terminal: $0.terminal ?? false)
            },
            budget: WarmUpStepBudget(maxPlannerDecisions: step.budget.maxPlannerDecisions,
                maxSeconds: step.budget.maxSeconds))
        let stopMarker = "Recovered; stop the test run."
        var fired = false
        var recovered = false
        var inputs: [PhonePromptAction] = []
        var directiveGoals: [String] = []
        var journaled: [PhoneVisionStep] = []
        let runner = PhoneVisualRunner(capture: { after in
            // Stop at the next frame after the recovery was journaled, so the
            // recovery branch itself (input, wait, or planner directive)
            // completes and nothing further is sent.
            if recovered { throw PhoneVisionError.unavailable(stopMarker) }
            return try frame(after: after)
        },
            decide: { goal, _, _ in
                if goal.contains("RECOVERY for failure mode '\(mode.id)'") { directiveGoals.append(goal) }
                if goal.contains(": Submit once.") { return .action(.tap(0.8, 0.2), reason: "Visible submit control") }
                if (goal.contains(": Next video.") || goal.contains(": Next post.")) && !goal.contains("already sent") {
                    return .action(.swipe(.up), reason: "Advance after verified completion")
                }
                return .finished("Current milestone verified from the screenshot")
            }, perform: { inputs.append($0) }, blockedReason: { nil },
            validateSubmissionAction: { _, _, _ in },
            classifyFailure: { _, script, stepID, playbackSummary in
                // The real classifier with a stub scorer that detects this
                // scenario's mode on the target step's first frame.
                guard script.identifier == scriptIdentifier, stepID == targetStepID, !fired else { return nil }
                fired = true
                return try await WarmUpFailureClassifier.classify(regions: [], scriptIdentifier: scriptIdentifier,
                    platform: network.rawValue, step: stepContract, playbackSummary: playbackSummary,
                    scorer: FailureStubScorer(winner: mode.id))
            })
        do {
            // The advance step only runs when another item remains.
            _ = try await runner.run(goal: "Platform: \(network.rawValue)", workflow: .warmUp,
                warmUpScript: WarmUpScript(network: network, activity: activity,
                    itemLimit: targetStepID == .advance ? 2 : 1, duration: 300),
                onProgress: { _ in }, onStep: { step in
                    journaled.append(step)
                    if step.failureCheck?.failureModeID == mode.id { recovered = true }
                })
            try expect(!terminal, "\(label): terminal mode did not stop the run")
        } catch let error as PhonePromptPlanningError {
            try expect(terminal, "\(label): non-terminal mode stopped the run: \(error.localizedDescription)")
            try expect(error.localizedDescription.contains("'\(step.id)'") && error.localizedDescription.contains("'\(mode.id)'")
                && error.localizedDescription.contains(mode.recovery),
                "\(label): needsInput did not name the step, mode, and contract recovery")
        } catch PhoneVisionError.unavailable(let message) {
            try expect(message == stopMarker && !terminal,
                "\(label): run failed past the recovery: \(message)")
        }
        try expect(fired, "\(label): the classifier never fired")
        let recoveryStep = journaled.last { $0.failureCheck?.failureModeID == mode.id }
        try expect(recoveryStep != nil && recoveryStep?.failureCheck?.terminal == terminal
            && recoveryStep?.failureCheck?.promptHash == "stub-\(mode.id)",
            "\(label): the detected mode was not journaled with its step")
        let branch: WarmUpFailureClassifier.RecoveryBranch = terminal
            ? .needsInput : WarmUpFailureClassifier.recoveryBranch(for: mode.id)
        switch branch {
        case .needsInput:
            let submitTap: [PhonePromptAction] = targetStepID == .verifySubmission ? [.tap(0.8, 0.2)] : []
            try expect(inputs == submitTap, "\(label): terminal mode sent input past detection")
            try expect(recoveryStep?.decisionSource == "Laya Core ML", "\(label): terminal detection was not local")
        case .perform(let action):
            try expect(inputs == [action], "\(label): runner-owned recovery sent \(inputs)")
            try expect(recoveryStep?.decisionSource == "Laya Core ML", "\(label): recovery input was not local")
        case .reobserve:
            try expect(inputs.isEmpty, "\(label): re-observation sent input before re-observing")
            try expect(recoveryStep?.input == nil && recoveryStep?.decisionSource == "Laya Core ML",
                "\(label): reobserve branch was not a local wait")
        case .plannerDirective:
            try expect(directiveGoals.count == 1, "\(label): recovery directive reached the planner \(directiveGoals.count) times")
            try expect(directiveGoals[0].contains(mode.detection) && directiveGoals[0].contains(mode.recovery),
                "\(label): directive lost the contract's detection or recovery text")
            if mode.id == "stalled-wait-loop" {
                try expect(directiveGoals[0].contains("PLAYBACK COMPLETION REVIEW"),
                    "\(label): stalled-wait-loop did not inject the playback completion review")
            }
            let advanceSwipe: [PhonePromptAction] = targetStepID == .advance ? [.swipe(.up)] : []
            try expect(inputs == advanceSwipe, "\(label): directive recovery sent unexpected input \(inputs)")
        }
    }

    /// An uncertain verdict (margin below threshold) is never an assertive
    /// branch: no recovery fires and the planner decides from the same frame.
    private static func failureCheckUncertainKeepsPlannerPath() async throws {
        let contract = try WarmUpContractFixture.load()
        guard let search = contract.platforms["X"]?.activities["watch"]?.steps.first(where: { $0.id == "search" }) else {
            throw TestError.failed("X watch search step missing from contract")
        }
        let stepContract = WarmUpStepContract(id: search.id, title: search.title, successCriteria: search.successCriteria,
            failureModes: search.failureModes.map {
                .init(id: $0.id, detection: $0.detection, recovery: $0.recovery, terminal: $0.terminal ?? false)
            },
            budget: WarmUpStepBudget(maxPlannerDecisions: search.budget.maxPlannerDecisions, maxSeconds: search.budget.maxSeconds))
        var plannerGoals: [String] = []
        var checks: [WarmUpFailureDecision] = []
        let runner = PhoneVisualRunner(capture: { after in try frame(after: after) },
            decide: { goal, _, _ in
                plannerGoals.append(goal)
                if goal.contains(": Verify account.") { return .finished("Planner-verified account") }
                return .needsInput("Stop after the uncertain check.")
            }, perform: { _ in throw TestError.failed("Uncertain verdict sent input") }, blockedReason: { nil },
            classifyFailure: { _, script, stepID, _ in
                guard stepID == .search else { return nil }
                let decision = try await WarmUpFailureClassifier.classify(regions: [],
                    scriptIdentifier: script.identifier, platform: "X", step: stepContract,
                    playbackSummary: nil, scorer: FailureStubScorer(winner: "search-not-focused", margin: 0.05))
                checks.append(decision)
                return decision
            })
        do {
            _ = try await runner.run(goal: "Platform: X", workflow: .warmUp,
                warmUpScript: WarmUpScript(network: .x, activity: .watch, itemLimit: 1, duration: 30),
                onProgress: { _ in }, onStep: { _ in })
            throw TestError.failed("Run continued past the stop marker")
        } catch is PhonePromptPlanningError { }
        try expect(checks.count == 1 && checks[0].uncertain && checks[0].failureModeID == nil,
            "Uncertain verdict was not returned conservatively")
        try expect(plannerGoals.count == 2 && plannerGoals.allSatisfy { !$0.contains("RECOVERY for failure mode") },
            "Uncertain verdict injected a recovery directive")
    }

    /// No scorer (nil verdict) is exactly the planner-only path: steps advance
    /// on the planner's own claims and no failure decision is journaled.
    private static func failureCheckUnavailableKeepsPlannerPath() async throws {
        var decideCalls = 0
        var failureChecks = 0
        let runner = PhoneVisualRunner(capture: { after in try frame(after: after) },
            decide: { _, _, _ in
                decideCalls += 1
                return decideCalls == 1
                    ? .finished("Planner-verified account")
                    : .needsInput("Stopping after the account check.")
            }, perform: { _ in throw TestError.failed("Unexpected input") }, blockedReason: { nil },
            classifyFailure: { _, _, _, _ in
                failureChecks += 1
                return nil
            })
        do {
            _ = try await runner.run(goal: "Platform: X", workflow: .warmUp,
                warmUpScript: WarmUpScript(network: .x, activity: .post, itemLimit: 1, duration: 30),
                onProgress: { _ in }, onStep: { _ in })
            throw TestError.failed("Run continued past the stop marker")
        } catch is PhonePromptPlanningError { }
        try expect(decideCalls == 2 && failureChecks == 1, "Nil verdicts changed the planner-only path")
    }

    /// INV-6: exhausting a step's decision budget ends in needsInput naming
    /// the step and the last evidence — before any further planner call, and
    /// never with input past the limit.
    private static func stepDecisionBudgetSendsNoInputPastLimit() async throws {
        var captures = 0
        var decisions = 0
        var inputs = 0
        let runner = PhoneVisualRunner(capture: { after in
            captures += 1
            // Alternate visibly distinct screens so the stalled-input guard
            // measures the waits, not JPEG-identical frames.
            return try frame(after: after, shade: captures.isMultiple(of: 2) ? 0 : 0.5)
        }, decide: { goal, _, _ in
            decisions += 1
            if goal.contains(": Verify account.") { return .finished("Account verified") }
            return .wait(seconds: 0.25, reason: "Still searching (decision \(decisions))")
        }, perform: { _ in inputs += 1 }, blockedReason: { nil },
            stepBudget: { _, stepID in
                stepID == .search ? WarmUpStepBudget(maxPlannerDecisions: 3, maxSeconds: 300) : nil
            })
        do {
            _ = try await runner.run(goal: "Platform: X", workflow: .warmUp,
                warmUpScript: WarmUpScript(network: .x, activity: .watch, itemLimit: 1, duration: 60),
                onProgress: { _ in }, onStep: { _ in })
            throw TestError.failed("A step ran past its decision budget")
        } catch let error as PhonePromptPlanningError {
            try expect(error.localizedDescription.contains("'search'")
                && error.localizedDescription.contains("3-decision budget")
                && error.localizedDescription.contains("Still searching (decision 4)"),
                "Decision-budget needsInput did not name the step, budget, and last evidence: \(error.localizedDescription)")
        }
        try expect(decisions == 4, "The planner was called past the step budget")
        try expect(inputs == 0, "Input was sent past the step budget")
    }

    /// INV-6: exhausting a step's time budget ends the same way, before any
    /// further planner call or input.
    private static func stepTimeBudgetSendsNoInputPastLimit() async throws {
        var captures = 0
        var decisions = 0
        var inputs = 0
        let runner = PhoneVisualRunner(capture: { after in
            captures += 1
            return try frame(after: after, shade: captures.isMultiple(of: 2) ? 0 : 0.5)
        }, decide: { goal, _, _ in
            decisions += 1
            if goal.contains(": Verify account.") { return .finished("Account verified") }
            try await Task.sleep(for: .milliseconds(400))
            return .wait(seconds: 0.25, reason: "Slow search (decision \(decisions))")
        }, perform: { _ in inputs += 1 }, blockedReason: { nil },
            stepBudget: { _, stepID in
                stepID == .search ? WarmUpStepBudget(maxPlannerDecisions: 50, maxSeconds: 1) : nil
            })
        do {
            _ = try await runner.run(goal: "Platform: X", workflow: .warmUp,
                warmUpScript: WarmUpScript(network: .x, activity: .watch, itemLimit: 1, duration: 60),
                onProgress: { _ in }, onStep: { _ in })
            throw TestError.failed("A step ran past its time budget")
        } catch let error as PhonePromptPlanningError {
            try expect(error.localizedDescription.contains("'search'")
                && error.localizedDescription.contains("1-second budget")
                && error.localizedDescription.contains("Slow search"),
                "Time-budget needsInput did not name the step, budget, and last evidence: \(error.localizedDescription)")
        }
        try expect(decisions <= 4 && inputs == 0, "The step ran past its time budget")
    }

    private static func submissionJournalPrecedesInput() async throws {
        var decisions = 0
        var states: [PhoneSubmissionCheckpoint.State] = []
        var inputs = 0
        let runner = PhoneVisualRunner(capture: { after in try frame(after: after) },
            decide: { goal, _, _ in
                decisions += 1
                switch decisions {
                case 1: return .finished("Matching account visible")
                case 2: return .finished("Requested text is ready in the composer")
                case 3: return .action(.tap(0.8, 0.2), reason: "Visible Post button")
                case 4:
                    try expect(goal.contains("Verify"), "Submit did not immediately transition to verification")
                    return .wait(seconds: 0.25, reason: "Upload in progress")
                default: return .finished("Published post visible under the correct account")
                }
            }, perform: { _ in
                try expect(states.last == .submitting, "Input was sent before the durable submission checkpoint")
                inputs += 1
            }, blockedReason: { nil }, validateSubmissionAction: { _, _, _ in })
        let script = WarmUpScript(network: .x, activity: .post, itemLimit: 1, duration: 30)
        _ = try await runner.run(goal: "Post supplied text", workflow: .warmUp, warmUpScript: script,
            onSubmissionCheckpoint: { states.append($0.state) }, onProgress: { _ in }, onStep: { _ in })
        try expect(inputs == 1 && states == [.preparing, .submitting, .confirmed], "Incorrect submission lifecycle")
    }

    private static func submissionStorageFailureBlocksInput() async throws {
        var decisions = 0
        var inputs = 0
        let runner = PhoneVisualRunner(capture: { after in try frame(after: after) },
            decide: { _, _, _ in
                decisions += 1
                return decisions < 3 ? .finished("Verified preparation") : .action(.tap(0.8, 0.2), reason: "Post")
            }, perform: { _ in inputs += 1 }, blockedReason: { nil }, validateSubmissionAction: { _, _, _ in })
        do {
            _ = try await runner.run(goal: "Post supplied text", workflow: .warmUp,
                warmUpScript: WarmUpScript(network: .x, activity: .post, itemLimit: 1, duration: 30),
                onSubmissionCheckpoint: { checkpoint in
                    if checkpoint.state == .submitting { throw TestError.failed("Disk unavailable") }
                }, onProgress: { _ in }, onStep: { _ in })
            throw TestError.failed("Ignored submission journal failure")
        } catch let error as TestError {
            try expect(error.localizedDescription == "Disk unavailable", "Wrong journal error")
        }
        try expect(inputs == 0, "Publishing continued without a saved checkpoint")
    }

    private static func submissionCannotBeRepeatedDuringVerification() async throws {
        var decisions = 0
        var inputs = 0
        var states: [PhoneSubmissionCheckpoint.State] = []
        let runner = PhoneVisualRunner(capture: { after in try frame(after: after) },
            decide: { _, _, _ in
                decisions += 1
                return decisions < 3 ? .finished("Verified preparation") : .action(.tap(0.8, 0.2), reason: "Try Post")
            }, perform: { _ in inputs += 1 }, blockedReason: { nil }, validateSubmissionAction: { _, _, _ in })
        do {
            _ = try await runner.run(goal: "Post supplied text", workflow: .warmUp,
                warmUpScript: WarmUpScript(network: .x, activity: .post, itemLimit: 1, duration: 30),
                onSubmissionCheckpoint: { states.append($0.state) }, onProgress: { _ in }, onStep: { _ in })
            throw TestError.failed("Allowed another tap during verification")
        } catch is PhonePromptPlanningError { }
        try expect(inputs == 1 && states == [.preparing, .submitting, .uncertain], "Ambiguous publish was retried or not flagged")
    }

    private static func scriptedWatchLoop() async throws {
        let script = WarmUpScript(network: .tikTok, activity: .watch, itemLimit: 2, duration: 30)
        let decisions: [(String, PhoneVisionDecision)] = [
            ("Verify account", .finished("Matching handle visible")),
            ("Search niche", .finished("Two-word query and suggestions visible")),
            ("Choose search result", .finished("Video grid visible")),
            ("Find video with >10K hearts", .finished("First video playing with 25K hearts visible")),
            ("Watch to completion", .wait(seconds: 0.25, reason: "Still playing")),
            ("Watch to completion", .finished("First video visibly restarted")),
            ("Next video", .action(.timedDrag(0.5, 0.8, 0.5, 0.2, duration: 0.4, pressDuration: 0, holdDuration: 0), reason: "Advance after verified completion")),
            ("Next video", .wait(seconds: 0.25, reason: "Transition loading")),
            ("Next video", .finished("Different video now playing")),
            ("Watch to completion", .finished("Second video ending verified")),
        ]
        var index = 0
        var inputs: [PhonePromptAction] = []
        var progress: [String] = []
        let runner = PhoneVisualRunner(capture: { after in try frame(after: after) },
            decide: { goal, _, _ in
                try expect(index < decisions.count, "Script continued after its item limit")
                let (title, decision) = decisions[index]
                try expect(goal.contains(": \(title)."), "Wrong active script step: \(title)")
                if index == 7 { try expect(goal.contains("already sent"), "Advance input not retained") }
                index += 1
                return decision
            }, perform: { inputs.append($0) }, blockedReason: { nil })
        let result = try await runner.run(goal: "Platform: TikTok", workflow: .warmUp, warmUpScript: script,
            onScriptProgress: { progress.append($0) }, onProgress: { _ in }, onStep: { _ in })
        try expect(index == decisions.count && inputs == [.swipe(.up)], "Not exactly one swipe between two completed videos")
        try expect(result.contains("completed") && progress.last?.contains("2/2 viewed") == true,
            "Script progress did not reach the item limit")
    }

    private static func scriptDeadline() async throws {
        var inputs = 0
        let runner = PhoneVisualRunner(capture: { after in try frame(after: after) },
            decide: { _, _, _ in
                try await Task.sleep(for: .seconds(1))
                return .action(.swipe(.up), reason: "Too late")
            }, perform: { _ in inputs += 1 }, blockedReason: { nil })
        let script = WarmUpScript(network: .tikTok, activity: .watch, itemLimit: 2, duration: 0.05)
        let result = try await runner.run(goal: "Platform: TikTok", workflow: .warmUp, warmUpScript: script,
            onProgress: { _ in }, onStep: { _ in })
        try expect(inputs == 0 && result.contains("time limit"), "Script sent input after its deadline")
        do {
            _ = try await runner.run(goal: "Publish provided content", workflow: .warmUp,
                warmUpScript: WarmUpScript(network: .x, activity: .post, itemLimit: 1, duration: 0.05),
                onProgress: { _ in }, onStep: { _ in })
            throw TestError.failed("Incomplete publication timed out as success")
        } catch is PhonePromptPlanningError { }
        try expect(inputs == 0, "Expired publication sent input")
    }

    private static func stateTreeBypassesModel() async throws {
        func text(_ label: String, _ x: Double, _ y: Double) -> PhonePlaybackTracker.TextRegion {
            .init(text: label, confidence: 1, bounds: CGRect(x: x, y: y, width: 0.1, height: 0.02))
        }
        let navigation = [text("Home", 0.05, 0.94), text("Inbox", 0.65, 0.94), text("Profile", 0.85, 0.94)]
        let feed = navigation + [text("For You", 0.5, 0.07), text("Following", 0.25, 0.07)]
        let profile = navigation + [text("@test", 0.3, 0.2), text("Edit profile", 0.2, 0.4),
                                    text("Followers", 0.4, 0.3), text("Following", 0.2, 0.3)]
        let results = [text("Search", 0.8, 0.08), text("Top", 0.1, 0.16), text("Videos", 0.3, 0.16), text("Users", 0.6, 0.16)]
        let player = [text("Search", 0.8, 0.08), text("Add comment...", 0.1, 0.93),
                      text("A caption for this video", 0.05, 0.83),
                      text("64.3K", 0.9, 0.5), text("783", 0.9, 0.6), text("1463", 0.9, 0.7)]
        let screens = [feed, profile, profile, [], results, player, player, player, player, player]
        var observations = 0
        var modelCalls = 0
        var inputs: [PhonePromptAction] = []
        var logged: [PhoneVisionStep] = []
        let runner = PhoneVisualRunner(capture: { after in try frame(after: after) }, decide: { goal, _, _ in
            modelCalls += 1
            try expect(goal.contains("STATE TREE:"), "Fallback lost current page context")
            if goal.contains("Advance sent: true") {
                return .finished("Different creator and caption verify the next video")
            }
            return .finished("Current milestone verified from the screenshot")
        }, perform: { inputs.append($0) }, blockedReason: { nil }, readText: { frame, platform in
            try! expect(observations < screens.count, "State tree exceeded expected route length")
            let regions = screens[observations]
            observations += 1
            return .init(sourceID: frame.sourceID, capturedAt: frame.capturedAt, platform: platform, regions: regions)
        })
        let result = try await runner.run(goal: "Account check: Verify exactly @test, ignoring case.", workflow: .warmUp,
            warmUpScript: .init(network: .tikTok, activity: .watch, itemLimit: 2, duration: 60),
            onProgress: { _ in }, onStep: { logged.append($0) })
        try expect(observations == 10 && modelCalls == 5, "Known pages failed to bypass model calls")
        try expect(inputs.count == 3 && inputs.last == .swipe(.up), "Navigation or advance was duplicated")
        try expect(logged.filter { $0.decisionSource == "state tree" }.count == 5, "Local decisions were not recorded")
        try expect(result.contains("completed"), "State tree did not finish the viewing goal")
    }

    private static func stateTreeDisconnectBlocksInput() async throws {
        var blocked = false
        var inputs = 0
        let runner = PhoneVisualRunner(capture: { after in try frame(after: after) },
            decide: { _, _, _ in throw TestError.failed("Recognized feed unexpectedly invoked model") },
            perform: { _ in inputs += 1 }, blockedReason: { blocked ? "Disconnected" : nil },
            readText: { frame, platform in
                let labels: [(String, Double, Double)] = [("Home", 0.05, 0.94), ("Inbox", 0.65, 0.94),
                    ("Profile", 0.85, 0.94), ("For You", 0.5, 0.07), ("Following", 0.25, 0.07)]
                return .init(sourceID: frame.sourceID, capturedAt: frame.capturedAt, platform: platform,
                    regions: labels.map { .init(text: $0.0, confidence: 1,
                        bounds: CGRect(x: $0.1, y: $0.2, width: 0.1, height: 0.02)) })
            })
        do {
            _ = try await runner.run(goal: "Watch", workflow: .warmUp,
                warmUpScript: .init(network: .tikTok, activity: .watch, itemLimit: 1, duration: 60),
                onProgress: { if $0.hasPrefix("Following the feed") { blocked = true } }, onStep: { _ in })
            throw TestError.failed("Disconnected local route continued")
        } catch PhoneVisionError.unavailable { }
        try expect(inputs == 0, "Local route bypassed availability checks")
    }

    private static func scriptedLongVideoSkip() async throws {
        var decisions = 0
        var inputs: [PhonePromptAction] = []
        var checkpoints: [WarmUpScriptCheckpoint] = []
        let runner = PhoneVisualRunner(capture: { after in try frame(after: after) },
            decide: { goal, _, _ in
                decisions += 1
                switch decisions {
                case 1...4: return .finished("Account, search, and qualifying starting video verified")
                case 5:
                    try expect(goal.contains("LONGER THAN 1:00"), "Duration exception never reached the planner")
                    return .action(.drag(0.5, 0.8, 0.5, 0.2), reason: "No readable total; same playing video advanced about 10% in 8 seconds, suggesting 80 seconds; skip without counting")
                case 6:
                    try expect(goal.contains("already sent"), "Skip must verify the new item before more input")
                    return .finished("Different video is now playing")
                default: return .finished("New 30-second video completed")
                }
            }, perform: { inputs.append($0) }, blockedReason: { nil })
        _ = try await runner.run(goal: "Watch one video", workflow: .warmUp,
            warmUpScript: WarmUpScript(network: .tikTok, activity: .watch, itemLimit: 1, duration: 60),
            onScriptCheckpoint: { checkpoints.append($0) }, onProgress: { _ in }, onStep: { _ in })
        try expect(inputs == [.swipe(.up)] && checkpoints.contains { $0.advanceSent && $0.itemsCompleted == 0 },
            "Long video was counted or skip dispatched more than once")
        try expect(checkpoints.last?.itemsCompleted == 1 && checkpoints.last?.isComplete == true,
            "Short video after the skip did not complete the viewing target")
    }

    private static func tiktokPlaybackReview() async throws {
        var inputs: [PhonePromptAction] = []
        var reviews = 0
        var captures = 0
        var firstFrameID: UUID?
        let runner = PhoneVisualRunner(capture: { after in
            captures += 1
            let image = try frame(after: after, shade: captures.isMultiple(of: 2) ? 0 : 1)
            if firstFrameID == nil { firstFrameID = image.id }
            return image
        }, decide: { _, _, history in
            if history.last?.playbackReviewRequested == true {
                reviews += 1
                try expect(history.last?.playbackStartFrame?.id == firstFrameID,
                    "Playback review lost the first waiting frame")
                try expect(history.last!.executionFeedback.contains("PLAYBACK COMPLETION REVIEW"),
                    "Playback review request never reaches the planner")
                if reviews == 1 {
                    try expect(inputs.isEmpty, "Advanced before completion was observed")
                    return .wait(seconds: 0.25, reason: "Still playing the first time")
                }
                return .action(.swipe(.up), reason: "Same video visibly restarted; advance after completion")
            }
            if history.last?.input == .swipe(.up) {
                try expect(history.last?.playbackStartFrame == nil, "Old video observation survived the swipe")
                return .wait(seconds: 0.25, reason: "A different video is now playing")
            }
            if inputs.count == 1 {
                try expect(history.last?.playbackStartFrame?.id != firstFrameID,
                    "Next video reused the previous video's watching start")
                return .finished("Next video verified; requested test limit reached")
            }
            return .wait(seconds: 0.25, reason: "Waiting for video completion")
        }, perform: { inputs.append($0) }, blockedReason: { nil })
        _ = try await runner.run(goal: "Warm Up\nPlatform: TikTok\nWatch within session limits", workflow: .warmUp,
            onProgress: { _ in }, onStep: {
                precondition($0.playbackStartFrame == nil, "UI history retained a full playback image")
            })
        try expect(reviews == 2 && inputs == [.swipe(.up)],
            "Completion review must continue an unfinished video, then send exactly one upward swipe")
    }

    private static func appSwitcherDiagnostic() async throws {
        for succeeds in [true, false] {
            var inputs: [PhonePromptAction] = []
            var observations = 0
            let runner = PhoneVisualRunner(capture: { after in try frame(after: after) },
                decide: { _, _, _ in throw TestError.failed("Diagnostic must not call the action planner") },
                perform: { inputs.append($0) }, blockedReason: { nil }, inspect: { _ in
                    observations += 1
                    let state: PhoneScreenObservation.State = succeeds ? .appSwitcher : .homeEditing
                    return .init(state: state, appCardsVisible: state == .appSwitcher, evidence: "Visible interface")
                })
            if succeeds {
                let result = try await runner.testAppSwitcher(onProgress: { _ in }, onStep: { _ in })
                try expect(result.contains("verified"), "Diagnostic lost successful verification")
            } else {
                try await expectFailure(.unavailable) {
                    try await runner.testAppSwitcher(onProgress: { _ in }, onStep: { _ in })
                }
            }
            try expect(inputs == [.press(.appSwitcher)], "Diagnostic repeated or dismissed apps")
            try expect(observations == 1, "Diagnostic accepted input dispatch as success")
        }
    }

    private static func observationOrderAndVerification() async throws {
        var events: [String] = []
        var frames: [PhoneScreenFrame] = []
        var steps: [PhoneVisionStep] = []
        var completedAt: Date?
        var decisionCount = 0
        let runner = PhoneVisualRunner(capture: { after in
            if let completedAt { try expect(after >= completedAt, "Capture requested a frame from before input completion") }
            events.append("capture")
            let next = try frame(after: after, shade: Double(frames.count) / 4)
            frames.append(next)
            return next
        }, decide: { goal, frame, history in
            try expect(goal == "Open settings", "The goal changed between decisions")
            try expect(frame == frames.last, "The model received the wrong frame")
            try expect(history.map(\.id) == steps.map(\.id), "The model did not receive the completed step history")
            if let latest = history.last {
                try expect(latest.afterFrame == frame && latest.beforeFrame != nil, "Missing before/after evidence")
                try expect(latest.screenChanged == true, "Changed screen was not reported")
                try expect(latest.input != nil, "Exact executed action was lost")
            }
            events.append("decide")
            decisionCount += 1
            switch decisionCount {
            case 1: return .action(.home, reason: "Show the Home screen.")
            case 2: return .action(.tap(0.25, 0.75), reason: "Settings is visible here.")
            default:
                try expect(frames.count == 3, "Finished without a post-action screen")
                return .finished("Settings is open on the phone.")
            }
        }, perform: { action in
            events.append("perform")
            try expect(action == .home || action == .tap(0.25, 0.75), "Unexpected input")
            completedAt = Date()
        }, blockedReason: { nil })
        let result = try await runner.run(goal: "Open settings", onProgress: { _ in }, onStep: { steps.append($0) })
        try expect(result == "Settings is open on the phone.", "The final screen result was lost")
        try expect(events == ["capture", "decide", "perform", "capture", "decide", "perform", "capture", "decide"], "Input ran without observing a fresh screen")
        try expect(steps.count == 2 && steps.map(\.number) == [1, 2], "Step log is incomplete")
        try expect(steps.allSatisfy { $0.beforeFrame == nil && $0.afterFrame == nil }, "UI history retained run screenshots")
        try expect(steps[0].capturedAt == frames[0].capturedAt && steps[1].capturedAt == frames[1].capturedAt, "Step logs lost source-frame timestamps")
        try expect(steps[1].detail == "Settings is visible here.", "The model's action reason was lost")
    }

    private static func rejectUnfreshFrames() async throws {
        for offset in [-121.0, -0.01, 0.0, 600.0] {
            var decisions = 0
            var inputs = 0
            let runner = PhoneVisualRunner(capture: { after in
                let valid = try frame(after: after)
                return copy(valid, capturedAt: after.addingTimeInterval(offset))
            }, decide: { _, _, _ in
                decisions += 1
                return .finished("Done")
            }, perform: { _ in inputs += 1 }, blockedReason: { nil })
            try await expectFailure(.stale) { try await runner.run(goal: "Open settings", onProgress: { _ in }, onStep: { _ in }) }
            try expect(decisions == 0 && inputs == 0, "A stale/future frame reached the model or driver")
        }
    }

    private static func rejectChangedSourceAndDuplicateID() async throws {
        for changeSource in [true, false] {
            let firstID = UUID()
            var captures = 0
            var decisions = 0
            var inputs = 0
            let runner = PhoneVisualRunner(capture: { after in
                captures += 1
                return try frame(after: after, id: changeSource ? UUID() : firstID,
                    source: changeSource && captures > 1 ? "Other Phone" : "Phone")
            }, decide: { _, _, _ in
                decisions += 1
                return .action(.home, reason: "Show the Home screen.")
            }, perform: { _ in inputs += 1 }, blockedReason: { nil })
            try await expectFailure(changeSource ? .source : .stale) {
                try await runner.run(goal: "Open settings", onProgress: { _ in }, onStep: { _ in })
            }
            try expect(inputs == 1 && decisions == 1 && captures == 2, "An invalid second frame was used for another input")
        }
    }

    private static func rejectMalformedImages() async throws {
        for invalidCase in 0..<6 {
            var decisions = 0
            let runner = PhoneVisualRunner(capture: { after in
                let good = try frame(after: after)
                switch invalidCase {
                case 0: return copy(good, data: Data())
                case 1: return copy(good, data: Data([0xFF, 0xD8, 0x01, 0x02, 0xFF, 0xD9]))
                case 2: return copy(good, width: 0)
                case 3: return copy(good, width: 999_999)
                case 4: return copy(good, width: good.pixelWidth + 1)
                default: return copy(good, source: "  ")
                }
            }, decide: { _, _, _ in
                decisions += 1
                return .finished("Done")
            }, perform: { _ in throw TestError.failed("Malformed image reached input driver") }, blockedReason: { nil })
            try await expectFailure(.unavailable) { try await runner.run(goal: "Open settings", onProgress: { _ in }, onStep: { _ in }) }
            try expect(decisions == 0, "Malformed image reached the model")
        }
    }

    private static func stopRepeatedInput() async throws {
        for waiting in [false, true] {
            var decisions = 0
            var inputs = 0
            var steps = 0
            let runner = PhoneVisualRunner(capture: { try frame(after: $0) }, decide: { _, _, history in
                if let previous = history.last {
                    try expect(previous.screenChanged == false, "Unchanged input did not reach the planner as execution feedback")
                }
                decisions += 1
                // Different wording must not bypass the repeated input guard.
                return waiting ? .wait(seconds: 0.25, reason: "Wait \(decisions)") : .action(.tap(0.5, 0.5), reason: "Tap \(decisions)")
            }, perform: { _ in inputs += 1 }, blockedReason: { nil })
            try await expectFailure(.unavailable) {
                try await runner.run(goal: "Open settings", onProgress: { _ in }, onStep: { _ in steps += 1 })
            }
            try expect(decisions == 3 && steps == 2, "Repeated unchanged screens did not stop at the third decision")
            try expect(inputs == (waiting ? 0 : 2), "The third blind input was dispatched")
        }
        // Identical actions remain allowed when their input screen has changed.
        var decisions = 0
        var inputs = 0
        let changing = PhoneVisualRunner(capture: { try frame(after: $0, shade: Double(decisions) / 5) }, decide: { _, _, _ in
            decisions += 1
            return decisions <= 3 ? .action(.swipe(.up), reason: "More content is below.") : .finished("The item is visible.")
        }, perform: { _ in inputs += 1 }, blockedReason: { nil })
        _ = try await changing.run(goal: "Find the item", onProgress: { _ in }, onStep: { _ in })
        try expect(inputs == 3, "Changing screens were incorrectly treated as a blind loop")
    }

    private static func rejectMalformedDecisions() async throws {
        let badDecisions: [PhoneVisionDecision] = [
            .action(.tap(.nan, 0), reason: "Tap"),
            .action(.drag(0, 0, 2, 0), reason: "Drag"),
            .action(.openApp("Settings"), reason: "Open Settings"),
            .action(.search("Settings"), reason: "Search"),
            .action(.typeText(String(repeating: "a", count: 101)), reason: "Type"),
            .action(.home, reason: ""), .action(.typeText("😀"), reason: "Type"),
            .wait(seconds: .infinity, reason: "Wait"), .wait(seconds: 4, reason: "Wait"),
            .finished(""), .needsInput(""),
        ]
        for decision in badDecisions {
            var inputs = 0
            let runner = PhoneVisualRunner(capture: { try frame(after: $0) }, decide: { _, _, _ in decision },
                perform: { _ in inputs += 1 }, blockedReason: { nil })
            try await expectFailure(.invalid) { try await runner.run(goal: "Open settings", onProgress: { _ in }, onStep: { _ in }) }
            try expect(inputs == 0, "Malformed decision sent input")
        }
    }

    /// One malformed answer is retried with the rejection spelled out, so the
    /// model can fix the unit instead of repeating the same mistake.
    private static func retryNamesTheRejection() async throws {
        var asks = 0
        var inputs: [PhonePromptAction] = []
        let runner = PhoneVisualRunner(capture: { try frame(after: $0) }, decide: { goal, _, _ in
            asks += 1
            switch asks {
            case 1:
                try expect(!goal.contains("PREVIOUS RESPONSE REJECTED"), "First ask already carried a rejection")
                return .action(.tap(1.5, 0.5), reason: "Tap")
            case 2:
                try expect(goal.contains("PREVIOUS RESPONSE REJECTED") && goal.contains("0 to 1"),
                    "Retry did not tell the model why its answer was rejected")
                return .action(.tap(0.5, 0.5), reason: "Tap")
            default:
                return .finished("Done")
            }
        }, perform: { inputs.append($0) }, blockedReason: { nil })
        _ = try await runner.run(goal: "Open settings", onProgress: { _ in }, onStep: { _ in })
        try expect(inputs == [.tap(0.5, 0.5)], "Corrected decision was not the one dispatched")
    }

    private static func requireClarification() async throws {
        let runner = PhoneVisualRunner(capture: { try frame(after: $0) }, decide: { _, _, _ in
            .needsInput("Which account should I choose?")
        }, perform: { _ in throw TestError.failed("Clarification dispatched input") }, blockedReason: { nil })
        do {
            _ = try await runner.run(goal: "Choose my account", onProgress: { _ in }, onStep: { _ in })
            throw TestError.failed("Clarification was reported as success")
        } catch let error as PhonePromptPlanningError {
            try expect(error.localizedDescription == "Which account should I choose?", "Clarification message was lost")
        }
    }

    private static func disconnectBeforeDispatch() async throws {
        for disconnectInStep in [true, false] {
            var connected = true
            var inputs = 0
            let runner = PhoneVisualRunner(capture: { try frame(after: $0) }, decide: { _, _, _ in
                if !disconnectInStep { connected = false }
                return .action(.home, reason: "Show the Home screen.")
            }, perform: { _ in inputs += 1 }, blockedReason: { connected ? nil : "Phone disconnected" })
            try await expectFailure(.unavailable) {
                try await runner.run(goal: "Open settings", onProgress: { _ in }, onStep: { _ in connected = false })
            }
            try expect(inputs == 0, "A disconnected phone received input")
        }
    }

    private static func cancelledModelCannotDispatch() async throws {
        let gate = Gate()
        var inputs = 0
        let runner = PhoneVisualRunner(capture: { try frame(after: $0) }, decide: { _, _, _ in
            await gate.wait() // Deliberately ignores cancellation until released.
            return .action(.home, reason: "Show the Home screen.")
        }, perform: { _ in inputs += 1 }, blockedReason: { nil })
        let task = Task { try await runner.run(goal: "Open settings", onProgress: { _ in }, onStep: { _ in }) }
        try await waitUntil { gate.waiting }
        task.cancel()
        do {
            _ = try await task.value
            throw TestError.failed("Cancelled model run returned success")
        } catch is CancellationError { }
        gate.release()
        await Task.yield()
        try expect(inputs == 0, "A late cancelled model result dispatched input")
    }

    private static func cancellationStopsRemainingInput() async throws {
        let gate = Gate()
        var inputs = 0
        var captures = 0
        let runner = PhoneVisualRunner(capture: {
            captures += 1
            return try frame(after: $0)
        }, decide: { _, _, _ in .action(.home, reason: "Show the Home screen.") }, perform: { _ in
            inputs += 1
            await gate.wait()
        }, blockedReason: { nil })
        let task = Task { try await runner.run(goal: "Open settings", onProgress: { _ in }, onStep: { _ in }) }
        try await waitUntil { gate.waiting }
        task.cancel()
        do {
            _ = try await task.value
            throw TestError.failed("Cancelled input run returned success")
        } catch is CancellationError { }
        gate.release()
        await Task.yield()
        try expect(inputs == 1 && captures == 1, "Cancelled input continued to another screen/action")
    }

    private static func decisionAndDurationLimits() async throws {
        var decisions = 0
        var inputs = 0
        let bounded = PhoneVisualRunner(capture: { try frame(after: $0, shade: Double(decisions) / 5) }, decide: { _, _, _ in
            decisions += 1
            return .action(.home, reason: "Show the Home screen.")
        }, perform: { _ in inputs += 1 }, blockedReason: { nil }, maximumSteps: 2)
        try await expectFailure(.limit) { try await bounded.run(goal: "Open settings", onProgress: { _ in }, onStep: { _ in }) }
        try expect(decisions == 2 && inputs == 2, "The decision limit was exceeded")

        let gate = Gate()
        var lateInputs = 0
        let timed = PhoneVisualRunner(capture: { try frame(after: $0) }, decide: { _, _, _ in
            await gate.wait()
            return .action(.home, reason: "Show the Home screen.")
        }, perform: { _ in lateInputs += 1 }, blockedReason: { nil }, maximumDuration: 0.05)
        try await expectFailure(.limit) { try await timed.run(goal: "Open settings", onProgress: { _ in }, onStep: { _ in }) }
        try expect(gate.waiting, "Timed test never entered the pending model")
        gate.release()
        await Task.yield()
        try expect(lateInputs == 0, "An expired model result dispatched input")
    }

    private static func failedInputStopsLoop() async throws {
        var captures = 0
        var inputs = 0
        let runner = PhoneVisualRunner(capture: {
            captures += 1
            return try frame(after: $0)
        }, decide: { _, _, _ in .action(.home, reason: "Show the Home screen.") }, perform: { _ in
            inputs += 1
            throw PhoneVisionError.unavailable("Bluetooth write failed")
        }, blockedReason: { nil })
        try await expectFailure(.unavailable) { try await runner.run(goal: "Open settings", onProgress: { _ in }, onStep: { _ in }) }
        try expect(captures == 1 && inputs == 1, "The loop continued after failed input")
    }

    private static func stopNearlyIdenticalTapLoop() async throws {
        var decisions = 0, inputs = 0
        let runner = PhoneVisualRunner(capture: { try frame(after: $0, shade: 0.5 + Double(decisions) * 0.003) }, decide: { _, _, _ in
            decisions += 1
            return .action(.tap(0.4 + Double(decisions) * 0.002, 0.6), reason: "Try the same icon again")
        }, perform: { _ in inputs += 1 }, blockedReason: { nil })
        try await expectFailure(.unavailable) { try await runner.run(goal: "Open Safari", onProgress: { _ in }, onStep: { _ in }) }
        try expect(inputs == 2, "JPEG noise or coordinate jitter bypassed the stalled-input guard")
    }

    private static func frame(after: Date, id: UUID = UUID(), source: String = "Phone", shade: Double = 0) throws -> PhoneScreenFrame {
        let width = 8
        let height = 12
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: colorSpace, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
            throw TestError.failed("Could not create image fixture")
        }
        context.setFillColor(red: shade, green: shade, blue: shade, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        guard let image = context.makeImage() else { throw TestError.failed("Could not create image fixture") }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil) else {
            throw TestError.failed("Could not create JPEG fixture")
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw TestError.failed("Could not encode JPEG fixture") }
        let timestamp = max(Date(), after.addingTimeInterval(0.000_001))
        return .init(id: id, capturedAt: timestamp, pixelWidth: width, pixelHeight: height, jpegData: data as Data, cgImage: image, sourceID: source)
    }

    private static func copy(_ frame: PhoneScreenFrame, capturedAt: Date? = nil, data: Data? = nil, width: Int? = nil, source: String? = nil) -> PhoneScreenFrame {
        .init(id: frame.id, capturedAt: capturedAt ?? frame.capturedAt, pixelWidth: width ?? frame.pixelWidth,
            pixelHeight: frame.pixelHeight, jpegData: data ?? frame.jpegData, cgImage: frame.cgImage, sourceID: source ?? frame.sourceID)
    }

    private enum ExpectedError { case stale, source, unavailable, invalid, limit }

    private static func expectFailure(_ expected: ExpectedError, operation: () async throws -> String) async throws {
        do {
            _ = try await operation()
            throw TestError.failed("Expected visual request to fail: \(expected)")
        } catch let error as PhoneVisionError {
            let matches: Bool = switch (expected, error) {
            case (.stale, .staleFrame), (.source, .sourceChanged), (.unavailable, .unavailable),
                 (.invalid, .invalidDecision), (.limit, .limitReached): true
            default: false
            }
            try expect(matches, "Unexpected visual failure: \(error)")
        } catch is PhonePromptPlanningError {
            try expect(expected == .invalid, "Unexpected planning failure")
        }
    }

    private static func waitUntil(_ predicate: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(2)
        while !predicate() {
            guard ContinuousClock.now < deadline else { throw TestError.failed("Timed out waiting for test state") }
            try await Task.sleep(for: .milliseconds(1))
        }
    }

    private static func expect(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        guard try condition() else { throw TestError.failed(message) }
    }
}
