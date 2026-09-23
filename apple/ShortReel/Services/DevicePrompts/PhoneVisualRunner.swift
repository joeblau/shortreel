import CoreGraphics
import Foundation
import ImageIO

@MainActor
final class PhoneVisualRunner {
    private let capture: (Date) async throws -> PhoneScreenFrame
    private let decide: (String, PhoneScreenFrame, [PhoneVisionStep]) async throws -> PhoneVisionDecision
    private let perform: (PhonePromptAction) async throws -> Void
    private let blockedReason: () -> String?
    private let maximumSteps: Int
    private let maximumDuration: TimeInterval
    private let inspect: ((PhoneScreenFrame) async throws -> PhoneScreenObservation)?
    private let observe: ((PhoneScreenFrame, String) async throws -> PhoneScreenObservation)?
    private let prepareCleanupAction: ((PhonePromptAction, PhoneScreenFrame) async throws -> PhonePromptAction)?
    private let validateSubmissionAction: (PhonePromptAction, PhoneScreenFrame, Bool) async throws -> Void
    private let readText: (PhoneScreenFrame, String) async -> PhonePlaybackTracker.Observation
    private let classifyAccount: ((PhoneScreenFrame, PhoneScreenObservation, WarmUpScript, String) async throws -> WarmUpAccountDecision?)?
    private let classifyFailure: ((PhoneScreenFrame, WarmUpScript, WarmUpScript.StepID, String?) async throws -> WarmUpFailureDecision?)?
    private let stepBudget: ((WarmUpScript, WarmUpScript.StepID) -> WarmUpStepBudget?)?
    private let compile: ((String, WarmUpScript?, @escaping @MainActor (String) -> Void) async throws -> PhoneTransactionPlan)?
    private let classify: ((PhoneTransactionQuestion) async throws -> String?)?
    private var isRunning = false

    init(capture: @escaping (Date) async throws -> PhoneScreenFrame,
         decide: @escaping (String, PhoneScreenFrame, [PhoneVisionStep]) async throws -> PhoneVisionDecision,
         perform: @escaping (PhonePromptAction) async throws -> Void,
         blockedReason: @escaping () -> String?,
         maximumSteps: Int = 30,
         maximumDuration: TimeInterval = 300,
         inspect: ((PhoneScreenFrame) async throws -> PhoneScreenObservation)? = nil,
         observe: ((PhoneScreenFrame, String) async throws -> PhoneScreenObservation)? = nil,
         prepareCleanupAction: ((PhonePromptAction, PhoneScreenFrame) async throws -> PhonePromptAction)? = nil,
         readText: @escaping (PhoneScreenFrame, String) async -> PhonePlaybackTracker.Observation = {
             await PhonePlaybackTracker.read(frame: $0, platform: $1)
         },
         validateSubmissionAction: @escaping (PhonePromptAction, PhoneScreenFrame, Bool) async throws -> Void = {
             try await PhoneSubmissionGuard.validate(action: $0, frame: $1, isFinalSubmission: $2)
         },
         classifyAccount: ((PhoneScreenFrame, PhoneScreenObservation, WarmUpScript, String) async throws -> WarmUpAccountDecision?)? = nil,
         classifyFailure: ((PhoneScreenFrame, WarmUpScript, WarmUpScript.StepID, String?) async throws -> WarmUpFailureDecision?)? = nil,
         stepBudget: ((WarmUpScript, WarmUpScript.StepID) -> WarmUpStepBudget?)? = nil,
         compile: ((String, WarmUpScript?, @escaping @MainActor (String) -> Void) async throws -> PhoneTransactionPlan)? = nil,
         classify: ((PhoneTransactionQuestion) async throws -> String?)? = nil) {
        self.compile = compile
        self.classify = classify
        self.readText = readText
        self.capture = capture
        self.decide = decide
        self.perform = perform
        self.blockedReason = blockedReason
        self.maximumSteps = min(maximumSteps, 30)
        self.maximumDuration = min(maximumDuration, 300)
        self.inspect = inspect
        self.observe = observe
        self.prepareCleanupAction = prepareCleanupAction
        self.validateSubmissionAction = validateSubmissionAction
        self.classifyAccount = classifyAccount
        self.classifyFailure = classifyFailure
        self.stepBudget = stepBudget
    }

    func testAppSwitcher(onProgress: @escaping @MainActor (String) -> Void,
                         onStep: @escaping (PhoneVisionStep) -> Void) async throws -> String {
        guard !isRunning, maximumDuration.isFinite, maximumDuration > 0, let inspect else {
            throw PhoneVisionError.unavailable("The App Switcher diagnostic is unavailable.")
        }
        isRunning = true
        defer { isRunning = false }
        let deadline = ContinuousClock.now + .seconds(maximumDuration)
        var after = Date()
        var source: String?
        var used = Set<UUID>()
        var opened = false
        for number in 1...2 {
            try checkAvailability(deadline: deadline)
            onProgress("Checking the phone’s screen…")
            let requestedAfter = after
            let frame = try await beforeDeadline(deadline) { [self] in try await capture(requestedAfter) }
            try validate(frame: frame, after: after, sourceID: source, usedIDs: used)
            source = frame.sourceID
            used.insert(frame.id)
            try checkAvailability(deadline: deadline)
            try checkFrameAge(frame)
            if opened {
                let observation = try await beforeDeadline(deadline) { try await inspect(frame) }
                try checkAvailability(deadline: deadline)
                try checkFrameAge(frame)
                guard observation.state == .appSwitcher, observation.appCardsVisible else {
                    throw PhoneVisionError.unavailable("App Switcher gesture was sent, but app preview cards were not verified. " + observation.summary)
                }
                return "App Switcher verified after the gesture. " + observation.evidence
            }
            let action: PhonePromptAction = .press(.appSwitcher)
            onStep(.init(id: UUID(), number: number, action: description(of: action),
                         detail: "Testing one swipe up from the bottom edge, holding before release; no apps will be dismissed.", capturedAt: frame.capturedAt, input: action))
            try checkAvailability(deadline: deadline)
            try await beforeDeadline(deadline) { [self] in try await perform(action) }
            after = Date()
            opened = action == .press(.appSwitcher)
        }
        throw PhoneVisionError.limitReached
    }

    func run(
        goal: String,
        workflow: DeviceWorkflow? = nil,
        warmUpScript: WarmUpScript? = nil,
        onScriptProgress: @escaping (String) -> Void = { _ in },
        onScriptCheckpoint: @escaping (WarmUpScriptCheckpoint) throws -> Void = { _ in },
        onSubmissionCheckpoint: @escaping (PhoneSubmissionCheckpoint) throws -> Void = { _ in },
        onTransactionPlan: @escaping (PhoneTransactionPlan) throws -> Void = { _ in },
        onTransactionCheckpoint: @escaping (PhoneTransactionCheckpoint) throws -> Void = { _ in },
        onProgress: @escaping @MainActor (String) -> Void,
        onStep: @escaping (PhoneVisionStep) -> Void
    ) async throws -> String {
        guard !isRunning else { throw PhoneVisionError.unavailable("A request is already running for this phone.") }
        guard let compile, let classify, let inspect else { throw PhoneTransactionError.unavailable }
        let goal = goal.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !goal.isEmpty, goal.count <= DevicePromptPlanner.maximumPromptLength else {
            throw PhonePromptPlanningError.needsClarification("Describe the request in at most \(DevicePromptPlanner.maximumPromptLength) characters.")
        }
        if workflow == .warmUp, warmUpScript == nil {
            throw PhonePromptPlanningError.needsClarification("Choose a warm-up script before running this workflow.")
        }
        if let script = warmUpScript {
            try script.validate()
            guard workflow == .warmUp, classifyAccount != nil, classifyFailure != nil, stepBudget != nil,
                  WarmUpStateTree.expectedHandle(goal) != nil else {
                throw PhonePromptPlanningError.needsClarification("Warm-up requires a script, its contracts, and the expected account handle.")
            }
        }
        if workflow == .clearHomeScreen, prepareCleanupAction == nil { throw PhoneTransactionError.unavailable }
        let limit = workflow?.limits.maximumSteps ?? maximumSteps
        let duration = min(workflow?.limits.maximumDuration ?? maximumDuration, warmUpScript?.duration ?? .infinity)
        guard limit > 0, duration.isFinite, duration > 0 else { throw PhoneVisionError.limitReached }
        isRunning = true
        defer { isRunning = false }
        let preparationDeadline = ContinuousClock.now + .seconds(min(240, maximumDuration))
        try checkAvailability(deadline: preparationDeadline)
        onProgress("Preparing workflow…")
        let plan = try await beforeDeadline(preparationDeadline) { try await compile(goal, warmUpScript, onProgress) }
        try plan.validate(script: warmUpScript)
        try checkAvailability(deadline: preparationDeadline)
        let deadline = ContinuousClock.now + .seconds(duration)
        try onTransactionPlan(plan)
        var cursor = warmUpScript.map { WarmUpScriptCursor(script: $0) }
        if let cursor { try onScriptCheckpoint(cursor.checkpoint) }
        var phaseIndex = 0
        var stateID = plan.phases[0].entry
        var visits: [String: Int] = [:]
        var phaseVisits = 0
        var phaseStarted = ContinuousClock.now
        var after = Date()
        var source: String?
        var used = Set<UUID>()
        var steps: [PhoneVisionStep] = []
        var pending: PhoneTransactionPlan.Branch?
        var pendingEvidence = ""
        var pendingIdentity = Set<String>()
        var advanceVerified = false
        var pendingInput: String?
        var verificationAttempts = 0
        var uncertainAttempts = 0
        var recoveryAttempts: [String: Int] = [:]
        var previousInput: InputFingerprint?
        var previousPixels: [UInt8]?
        var repeatedInputs = 0
        var playback = PhonePlaybackTracker()
        var visualPlayback = PhoneVideoProgressTracker()
        var dwell = PhoneWatchDwell()
        var sawReplay = false
        var submission: PhoneSubmissionCheckpoint?
        var upcoming: (phase: Int, state: String)?
        var reused: (frame: PhoneScreenFrame, observation: PhoneScreenObservation, text: PhonePlaybackTracker.Observation)?
        func stateFocus(_ state: PhoneTransactionPlan.State) -> String {
            state.question ?? "Describe the visible facts relevant to these conditions:\n" + state.branches.map(\.condition).joined(separator: "\n")
        }
        func reuseTarget(after branch: PhoneTransactionPlan.Branch) -> (phase: Int, state: String)? {
            let target: (phase: Int, state: String)
            if plan.phases[phaseIndex].states.contains(where: { $0.id == branch.next }) {
                target = (phaseIndex, branch.next)
            } else if branch.next == "$done", phaseIndex + 1 < plan.phases.count {
                target = (phaseIndex + 1, plan.phases[phaseIndex + 1].entry)
            } else { return nil }
            let next = plan.phases[target.phase]
            guard !["consume", "advance"].contains(next.id),
                  let state = next.states.first(where: { $0.id == target.state }),
                  state.check == nil || state.check == .query else { return nil }
            return target
        }
        func recordSubmission(_ status: PhoneSubmissionCheckpoint.State) throws {
            let checkpoint = PhoneSubmissionCheckpoint(state: status,
                activity: warmUpScript?.activity.rawValue ?? "", updatedAt: Date(),
                detail: status == .confirmed ? "Publication verified." : "Check the phone before retrying any unverified publication.")
            try onSubmissionCheckpoint(checkpoint)
            submission = checkpoint
        }
        defer { if submission?.state == .submitting { try? recordSubmission(.uncertain) } }
        func checkpoint(_ status: PhoneTransactionCheckpoint.Status, branch: String? = nil, input: String? = nil) throws {
            try onTransactionCheckpoint(.init(phase: plan.phases[phaseIndex].id, state: stateID,
                branch: branch, status: status, input: input ?? (status == .verifying ? pendingInput : nil), visits: visits))
        }
        var restarts = 0
        func resetPhase() {
            stateID = plan.phases[phaseIndex].entry
            pending = nil
            pendingInput = nil
            pendingEvidence = ""
            pendingIdentity = []
            verificationAttempts = 0
            uncertainAttempts = 0
            visits = [:]
            recoveryAttempts = [:]
            phaseVisits = 0
            phaseStarted = ContinuousClock.now
            reused = nil
            playback.reset()
            visualPlayback.reset()
            dwell.reset()
            sawReplay = false
            after = Date()
        }
        func restart(after error: Error, number: Int, frame: PhoneScreenFrame) async throws {
            if var active = cursor, active.step.id == .like || active.step.id == .follow {
                let skipped = active.step.title
                try active.finishStep()
                cursor = active
                try onScriptCheckpoint(active.checkpoint)
                guard !active.isComplete,
                      let next = plan.phases.firstIndex(where: { $0.id == active.step.id.rawValue }) else { throw error }
                onStep(.init(id: UUID(), number: number, action: "Skipped \(skipped.lowercased())",
                    detail: "Engagement is optional and never retapped: \(error.localizedDescription)",
                    capturedAt: frame.capturedAt, decisionSource: "Semantic If recovery"))
                phaseIndex = next
                resetPhase()
                try checkpoint(.observing)
                return
            }
            guard var active = cursor, restarts < Self.maximumRestarts, submission == nil, !active.submissionSent,
                  ![.prepareSubmission, .submit, .verifySubmission].contains(active.step.id),
                  plan.phases.first?.id == WarmUpScript.StepID.account.rawValue else { throw error }
            restarts += 1
            onProgress("Restarting from Home…")
            pendingInput = PhonePromptAction.home.modelInputDescription
            try checkpoint(.dispatching, branch: "restart", input: pendingInput)
            onStep(.init(id: UUID(), number: number, action: "Restarting from Home",
                detail: "Recovery \(restarts) of \(Self.maximumRestarts) after: \(error.localizedDescription) Completed items are kept.",
                capturedAt: frame.capturedAt, input: .home, decisionSource: "Semantic If recovery"))
            try await beforeDeadline(deadline) { [self] in try await perform(.home) }
            active.restart()
            cursor = active
            try onScriptCheckpoint(active.checkpoint)
            phaseIndex = 0
            stateID = plan.phases[0].entry
            pending = nil
            pendingInput = nil
            pendingEvidence = ""
            pendingIdentity = []
            advanceVerified = false
            verificationAttempts = 0
            uncertainAttempts = 0
            visits = [:]
            recoveryAttempts = [:]
            phaseVisits = 0
            phaseStarted = ContinuousClock.now
            reused = nil
            previousInput = nil
            previousPixels = nil
            repeatedInputs = 0
            playback.reset()
            visualPlayback.reset()
            dwell.reset()
            sawReplay = false
            try checkpoint(.observing)
            after = Date()
        }
        for number in 1...limit {
            try checkAvailability(deadline: deadline)
            let phase = plan.phases[phaseIndex]
            guard let state = phase.states.first(where: { $0.id == stateID }) else { throw PhoneTransactionError.invalidPlan }
            phaseVisits += 1
            var operationDeadline = deadline
            if let cursor {
                guard let budget = stepBudget?(cursor.script, cursor.step.id) else { throw PhoneTransactionError.unavailable }
                operationDeadline = min(deadline, phaseStarted + .seconds(budget.maxSeconds))
                guard phaseVisits <= budget.maxPlannerDecisions else { throw PhoneVisionError.limitReached }
                onScriptProgress(cursor.progress)
            }
            try checkAvailability(deadline: operationDeadline)
            try checkpoint(pending == nil ? .observing : .verifying, branch: pending?.id)
            upcoming = pending.flatMap(reuseTarget)
            var focus = pending.map { "Describe the current evidence for this expected result: \($0.expected)" } ?? stateFocus(state)
            if let upcoming, let next = plan.phases[upcoming.phase].states.first(where: { $0.id == upcoming.state }) {
                focus += "\nAlso answer the next check on this same screen, in evidence and checkEvidence: " + stateFocus(next)
            }
            let frame: PhoneScreenFrame
            let observation: PhoneScreenObservation
            let text: PhonePlaybackTracker.Observation
            if let reuse = reused {
                reused = nil
                (frame, observation, text) = reuse
            } else {
                let requestedAfter = after
                frame = try await beforeDeadline(operationDeadline) { [self] in try await capture(requestedAfter) }
                try validate(frame: frame, after: after, sourceID: source, usedIDs: used)
                source = frame.sourceID
                used.insert(frame.id)
                onProgress(pending == nil ? "Reading the iPhone screen…" : "Checking the result on the iPhone…")
                let request = focus
                observation = try await beforeDeadline(operationDeadline) { [self] in
                    if let observe { return try await observe(frame, request) }
                    return try await inspect(frame)
                }
                let platform = warmUpScript?.network.rawValue ?? ""
                text = try await beforeDeadline(operationDeadline) { [self] in await readText(frame, platform) }
            }
            try checkAvailability(deadline: operationDeadline)
            try checkFrameAge(frame)
            if let last = steps.indices.last, steps[last].input != nil, steps[last].screenChanged == nil {
                if let before = steps[last].beforeFrame {
                    steps[last].screenChanged = !Self.sameScreen(Self.screenFingerprint(before.cgImage), Self.screenFingerprint(frame.cgImage))
                    steps[last].beforeFrame = nil
                }
            }
            let screenText = text.regions.map(\.text).filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                .joined(separator: "\n")
            let evidence = plan.watchQuery != nil
                ? (observation.checkEvidence ?? observation.evidence)
                : observation.evidence + (screenText.isEmpty ? "" : "\nOCR:\n" + screenText)
            if pending == nil, let screens = state.requiredScreens, !screens.contains(observation.state) {
                onStep(.init(id: UUID(), number: number, action: "Unexpected screen",
                    detail: "Observed: \(observation.evidence)", capturedAt: frame.capturedAt))
                try await restart(after: PhonePromptPlanningError.needsClarification(
                    "The screen changed before this workflow step. No input was sent. " + observation.evidence), number: number, frame: frame)
                continue
            }
            var context = evidence
            var playbackEvidence: PhonePlaybackEvidence?
            if cursor?.step.id == .consume, cursor?.script.usesVideo == true {
                let measured = playback.observe(text)
                let visual = visualPlayback.observe(observation.video, at: frame.capturedAt)
                let result = plan.watchQuery != nil
                    ? PhonePlaybackEvidence(summary: measured.summary + "\n" + visual.summary,
                        replayCandidate: measured.replayCandidate || visual.replayCandidate,
                        durationSeconds: measured.durationSeconds ?? visual.durationSeconds,
                        isAdvancing: measured.isAdvancing || visual.isAdvancing)
                    : measured
                playbackEvidence = result
                sawReplay = sawReplay || result.replayCandidate
                if let limit = cursor?.script.maximumVideoDurationSeconds,
                   dwell.observe(identity: observation.video?.identity ?? PhoneWatchChecks.identity(in: text),
                       playing: observation.video?.playing, at: frame.capturedAt, duration: result.durationSeconds, limit: limit) {
                    sawReplay = true
                    context += "\nPlayback: the same video played continuously past its full length."
                }
                context += "\nPlayback: \(result.summary)\nMeasured replay in this step: \(sawReplay)."
            }
            var account: WarmUpAccountDecision?
            var failure: WarmUpFailureDecision?
            if let cursor {
                if cursor.step.id != .account, plan.watchQuery == nil {
                    context += "\nPhase: \(cursor.step.id.rawValue). Advance already sent: \(cursor.advanceSent). Submission already sent: \(cursor.submissionSent)."
                }
                if cursor.step.id == .account {
                    if state.accountGate == true || !phase.states.contains(where: { $0.accountGate == true }) {
                        guard let classifyAccount else { throw PhoneTransactionError.unavailable }
                        account = try await beforeDeadline(operationDeadline) { try await classifyAccount(frame, observation, cursor.script, goal) }
                        guard let account else { throw PhoneTransactionError.unavailable }
                        if account.outcome == .mismatch || account.outcome == .signedOut {
                            throw PhonePromptPlanningError.needsClarification(account.evidence)
                        }
                        if state.accountGate == true || state.branches.contains(where: { $0.next == "$done" }) {
                            context += "\nAccount: \(account.outcome.rawValue)."
                        }
                    }
                } else if plan.watchQuery == nil, let classifyFailure {
                    let summary = playbackEvidence?.summary
                    failure = try await beforeDeadline(operationDeadline) { try await classifyFailure(frame, cursor.script, cursor.step.id, summary) }
                    guard let failure else { throw PhoneTransactionError.unavailable }
                    if failure.terminal, failure.failureModeID != nil {
                        throw PhonePromptPlanningError.needsClarification(failure.evidence)
                    }
                    context += "\nFailure: \(failure.failureModeID ?? "none")."
                }
            }
            var question: PhoneTransactionQuestion
            if let pending {
                let comparesItems = pending.command?.kind == .swipe && (phase.id == "consume" || phase.id == "advance")
                let verificationEvidence = plan.watchQuery != nil && !comparesItems ? evidence : context + "\nBefore input:\n" + pendingEvidence
                question = .init(id: "\(phase.id).\(state.id).verify", evidence: verificationEvidence,
                    options: [.init(id: "confirmed", description: pending.expected),
                              .init(id: "pending", description: "The expected result is not yet visible, or is ambiguous."),
                              .init(id: "failed", description: "The input failed or an error or unexpected screen is visible.")])
            } else {
                let key = "\(phase.id).\(state.id)"
                visits[key, default: 0] += 1
                guard visits[key, default: 0] <= state.maximumVisits else {
                    try await restart(after: PhoneVisionError.limitReached, number: number, frame: frame)
                    continue
                }
                // Laya matches words, not negation ("not the Home Screen" scores as home, "signed-in" as login),
                // so only offer branches the structured screen state and on-screen sign-in controls allow.
                let signInVisible = LayaAccountPrompt.hasSignInControls(text.regions.filter { $0.confidence >= 0.6 }.map(\.text))
                let engagementState = Self.engagementBranch(check: state.check, video: observation.video)
                let keyboard = observation.keyboardVisible ?? (PhoneWatchChecks.keyboardVisible(in: text) ? true : nil)
                let branches = state.branches.filter { branch in
                    (branch.requiredScreens?.contains(observation.state) ?? true)
                        && (branch.keyboard == nil || keyboard == nil || branch.keyboard == keyboard)
                        && (plan.watchQuery == nil || branch.id != "login" || signInVisible)
                        && (engagementState.map { $0 == branch.id } ?? true)
                }
                // Taps toggle likes and follows, so engage only on Codex's explicit structured reading.
                guard !branches.isEmpty, engagementState != nil || (state.check != .like && state.check != .follow) else {
                    try await restart(after: PhoneTransactionError.uncertain, number: number, frame: frame)
                    continue
                }
                question = .init(id: key, evidence: context,
                    options: branches.map { .init(id: $0.id, description: $0.condition) }
                        + [.init(id: "unknown", description: "None of the listed conditions is clearly supported by the current evidence.")],
                    question: state.question ?? "Which condition is clearly supported by the current screen evidence?")
            }
            if pending == nil, let check = state.check,
               let visualQuestion = PhoneWatchChecks.question(id: question.id, check: check, evidence: evidence) {
                question = visualQuestion
            }
            let verifyingWatchSwipe = plan.watchQuery != nil && pending?.command?.kind == .swipe &&
                (phase.id == "consume" || phase.id == "advance")
            if verifyingWatchSwipe,
               let visualQuestion = PhoneWatchChecks.question(id: question.id, check: .advance, evidence: evidence) {
                question = visualQuestion
            }
            let verifyingWatchPlayback = plan.watchQuery != nil && pending != nil && state.check == .playback && !verifyingWatchSwipe
            if verifyingWatchPlayback,
               let visualQuestion = PhoneWatchChecks.question(id: question.id, check: .playback, evidence: evidence) {
                question = visualQuestion
            }
            if plan.watchQuery != nil, observation.video != nil, question.options.contains(where: { $0.id == "player" }) {
                question = .init(id: question.id, evidence: question.evidence,
                    options: question.options.filter { !["results", "profile"].contains($0.id) }, question: question.question)
            }
            onProgress("Checking the current screen…")
            var selected: String?
            if pending == nil, state.accountGate == true {
                guard let account else { throw PhoneTransactionError.unavailable }
                selected = account.outcome == .matches ? "matches" : "unreadable"
            } else if let failure, failure.uncertain {
                selected = nil
            } else if pending == nil, let mode = failure?.failureModeID {
                guard state.branches.contains(where: { $0.id == mode }) else {
                    throw PhonePromptPlanningError.needsClarification("No saved recovery for \(mode) in \(state.id). Check the phone before continuing.")
                }
                recoveryAttempts[mode, default: 0] += 1
                guard recoveryAttempts[mode, default: 0] <= WarmUpFailureClassifier.attemptLimit(for: mode) else {
                    throw PhoneTransactionError.uncertain
                }
                selected = mode
            } else {
                let currentQuestion = question
                selected = try await beforeDeadline(operationDeadline) { try await classify(currentQuestion) }
                if let answer = selected, !currentQuestion.options.contains(where: { $0.id == answer }) { selected = nil }
            }
            if pending == nil, let check = state.check {
                selected = PhoneWatchChecks.branch(for: selected, check: check, evidence: observation.evidence,
                    duration: playbackEvidence?.durationSeconds, replay: sawReplay, advanceSent: cursor?.advanceSent == true)
                if check == .advance, selected == "alreadySent", !advanceVerified { selected = nil }
            }
            if verifyingWatchSwipe { selected = selected == "player" ? "confirmed" : nil }
            if verifyingWatchPlayback {
                selected = selected == "playing" || (pending?.command?.kind == .wait && selected == "paused") ? "confirmed" : nil
            }
            try checkAvailability(deadline: operationDeadline)
            try checkFrameAge(frame)
            func recordUnverifiedObservation() {
                let step = PhoneVisionStep(id: UUID(), number: number, action: "Screen condition not verified",
                    detail: "Observed: \(observation.evidence)\nChecking: \(focus)", capturedAt: frame.capturedAt)
                steps.append(step)
                onStep(step)
            }
            let branch: PhoneTransactionPlan.Branch
            var verified = false
            if let awaiting = pending {
                if let query = plan.watchQuery, awaiting.command?.kind == .typeText,
                   awaiting.command?.value == query, !PhoneWatchChecks.queryVisible(query, in: text) {
                    selected = nil
                }
                if plan.watchQuery != nil, awaiting.command?.kind == .swipe,
                   phase.id == "consume" || phase.id == "advance" {
                    let currentIdentity = observation.video?.identity ?? PhoneWatchChecks.identity(in: text)
                    if pendingIdentity.count < 2 || currentIdentity.count < 2 || currentIdentity == pendingIdentity {
                        selected = nil
                    } else if selected == "confirmed" { advanceVerified = true }
                }
                if Self.engagementBranch(check: state.check, video: observation.video) == awaiting.id { selected = nil }
                guard selected == "confirmed",
                      awaiting.expectedScreen == nil || awaiting.expectedScreen == observation.state else {
                    recordUnverifiedObservation()
                    verificationAttempts += 1
                    if awaiting.command?.kind == .home, observation.state != .home, verificationAttempts < 3 {
                        try await beforeDeadline(operationDeadline) { [self] in try await perform(.home) }
                        after = Date()
                        continue
                    }
                    guard selected != "failed", verificationAttempts < 3 else {
                        try await restart(after: PhoneTransactionError.uncertain, number: number, frame: frame)
                        continue
                    }
                    try await beforeDeadline(operationDeadline) { try await Task.sleep(for: .seconds(1)) }
                    after = Date()
                    continue
                }
                branch = awaiting
                verified = true
                pending = nil
                pendingInput = nil
                verificationAttempts = 0
            } else {
                guard let selected, selected != "unknown" else {
                    recordUnverifiedObservation()
                    uncertainAttempts += 1
                    guard uncertainAttempts < 3 else {
                        try await restart(after: PhoneTransactionError.uncertain, number: number, frame: frame)
                        continue
                    }
                    try await beforeDeadline(operationDeadline) { try await Task.sleep(for: .seconds(1)) }
                    after = Date()
                    continue
                }
                guard let chosen = state.branches.first(where: { $0.id == selected }) else { throw PhoneTransactionError.invalidPlan }
                guard chosen.requiredScreens?.contains(observation.state) ?? true else {
                    recordUnverifiedObservation()
                    try await restart(after: PhoneTransactionError.uncertain, number: number, frame: frame)
                    continue
                }
                branch = chosen
                uncertainAttempts = 0
                if let command = branch.command {
                    var decision: PhoneVisionDecision?
                    if command.needsLocation {
                        decision = try await beforeDeadline(operationDeadline) { [self] in
                            try await decide(command.locatorRequest, frame, [])
                        }
                    }
                    let action: PhonePromptAction?
                    do { action = try command.resolved(using: decision) }
                    catch {
                        if state.check == .like || state.check == .follow {
                            try await restart(after: error, number: number, frame: frame)
                            continue
                        }
                        // The target may not be on screen yet (a splash or loading frame): retry on a fresh frame.
                        guard error is PhonePromptPlanningError || (error as? PhoneTransactionError) == .invalidLocation else { throw error }
                        recordUnverifiedObservation()
                        uncertainAttempts += 1
                        guard uncertainAttempts < 3 else {
                            try await restart(after: error, number: number, frame: frame)
                            continue
                        }
                        try await beforeDeadline(operationDeadline) { try await Task.sleep(for: .seconds(1)) }
                        after = Date()
                        continue
                    }
                    try checkAvailability(deadline: operationDeadline)
                    try checkFrameAge(frame)
                    if var action {
                        try DevicePromptPlanner.validate(.init(actions: [action]))
                        try cursor?.validate(action, observedVideoDuration: playbackEvidence?.durationSeconds)
                        if cursor?.step.id == .consume, action == .swipe(.up) {
                            guard let limit = cursor?.script.maximumVideoDurationSeconds,
                                  let duration = playbackEvidence?.durationSeconds, duration > limit else {
                                throw PhoneTransactionError.uncertain
                            }
                        }
                        if workflow == .clearHomeScreen, let prepareCleanupAction {
                            let proposed = action
                            let checked = try await beforeDeadline(operationDeadline) { try await prepareCleanupAction(proposed, frame) }
                            if case .tap = checked, case .tap = action { action = checked }
                            else if checked != action { throw PhoneTransactionError.invalidLocation }
                        }
                        if cursor?.step.id == .prepareSubmission || cursor?.step.id == .submit || workflow == .createContent {
                            let final = cursor?.step.id == .submit
                            let proposed = action
                            try await beforeDeadline(operationDeadline) { [self] in try await validateSubmissionAction(proposed, frame, final) }
                        }
                        try checkRepeatedInput(.action(action), pixels: Self.screenFingerprint(frame.cgImage),
                            previousInput: &previousInput, previousPixels: &previousPixels, repeatedInputs: &repeatedInputs)
                        if cursor?.step.id == .submit {
                            guard submission?.state == .preparing else { throw PhoneTransactionError.uncertain }
                            try recordSubmission(.submitting)
                        }
                        pendingInput = action.modelInputDescription
                        try checkpoint(.dispatching, branch: branch.id, input: pendingInput)
                        let step = PhoneVisionStep(id: UUID(), number: number, action: description(of: action),
                            detail: "Observed: \(observation.evidence)\nExpected after input: \(branch.expected)", capturedAt: frame.capturedAt,
                            input: action, decisionSource: "Semantic If transaction", accountCheck: account, failureCheck: failure)
                        onStep(step)
                        try checkAvailability(deadline: operationDeadline)
                        try checkFrameAge(frame)
                        let dispatchedAction = action
                        if plan.watchQuery != nil, action == .swipe(.up), phase.id == "consume" || phase.id == "advance" {
                            pendingIdentity = observation.video?.identity ?? PhoneWatchChecks.identity(in: text)
                            guard pendingIdentity.count >= 2 else { throw PhoneTransactionError.uncertain }
                            advanceVerified = false
                        }
                        try await beforeDeadline(operationDeadline) { [self] in try await perform(dispatchedAction) }
                        cursor?.didPerform(action)
                        if let cursor { try onScriptCheckpoint(cursor.checkpoint) }
                        var capturedStep = step
                        capturedStep.beforeFrame = frame
                        steps.append(capturedStep)
                        playback.reset()
                        visualPlayback.reset()
                        dwell.reset()
                        sawReplay = false
                    } else {
                        try await beforeDeadline(operationDeadline) { try await Task.sleep(for: .seconds(command.seconds)) }
                    }
                    pending = branch
                    pendingEvidence = evidence
                    try checkpoint(.verifying, branch: branch.id)
                    after = Date()
                    continue
                }
            }
            onStep(.init(id: UUID(), number: number, action: branch.next == "$stop" ? "Stopped at a workflow condition" : "Checked the current screen",
                detail: "Observed: \(observation.evidence)\nMatched: \(branch.command == nil ? branch.condition : branch.expected)", capturedAt: frame.capturedAt,
                decisionSource: "Laya Core ML", accountCheck: account, failureCheck: failure))
            try checkAvailability(deadline: operationDeadline)
            if branch.next == "$stop" { throw PhonePromptPlanningError.needsClarification(branch.condition) }
            let cursorMoved = cursor.map { $0.step.id.rawValue != phase.id } ?? false
            if branch.next == "$done" || cursorMoved {
                if !cursorMoved, var active = cursor {
                    if active.step.id == .account, account?.outcome != .matches { throw PhoneTransactionError.uncertain }
                    if active.step.id == .consume, active.script.usesVideo, !sawReplay { throw PhoneTransactionError.uncertain }
                    if active.step.id == .prepareSubmission { try recordSubmission(.preparing) }
                    if active.step.id == .verifySubmission { try recordSubmission(.confirmed) }
                    try active.finishStep()
                    cursor = active
                    try onScriptCheckpoint(active.checkpoint)
                }
                let finished = cursor?.isComplete ?? (phaseIndex + 1 == plan.phases.count)
                if finished {
                    if workflow == .clearHomeScreen {
                        guard observation.state == .home, Self.hasCleanupSweep(steps) else { throw PhoneTransactionError.uncertain }
                    }
                    try checkpoint(.completed, branch: branch.id)
                    return cursor.map { "Verified \($0.itemsCompleted) item(s). Workflow completed." } ?? "Workflow completed and verified."
                }
                if let cursor {
                    guard let next = plan.phases.firstIndex(where: { $0.id == cursor.step.id.rawValue }) else { throw PhoneTransactionError.invalidPlan }
                    phaseIndex = next
                } else { phaseIndex += 1 }
                stateID = plan.phases[phaseIndex].entry
                visits = [:]
                recoveryAttempts = [:]
                phaseVisits = 0
                phaseStarted = ContinuousClock.now
                if cursor?.step.id == .consume { advanceVerified = false }
                playback.reset()
                visualPlayback.reset()
                dwell.reset()
                sawReplay = false
            } else { stateID = branch.next }
            if verified, let upcoming, upcoming == (phaseIndex, stateID) {
                reused = (frame, observation, text)
            }
            try checkpoint(.observing)
            after = Date()
        }
        throw PhoneVisionError.limitReached
    }

    static let maximumRestarts = 2

    /// The branch a like/follow state must take according to Codex's structured video fields, if reported.
    static func engagementBranch(check: PhoneTransactionPlan.State.Check?, video: PhoneScreenObservation.Video?) -> String? {
        switch check {
        case .like: video?.liked.map { $0 ? "liked" : "unliked" }
        case .follow: video?.followButtonVisible.map { $0 ? "available" : "following" }
        default: nil
        }
    }

    private func checkAvailability(deadline: ContinuousClock.Instant) throws {
        try Task.checkCancellation()
        guard ContinuousClock.now < deadline else { throw PhoneVisionError.limitReached }
        if let reason = blockedReason() { throw PhoneVisionError.unavailable(reason) }
    }

    private func validate(frame: PhoneScreenFrame, after: Date, sourceID: String?, usedIDs: Set<UUID>) throws {
        guard frame.capturedAt.timeIntervalSinceReferenceDate.isFinite,
              frame.capturedAt > after, !usedIDs.contains(frame.id) else {
            throw PhoneVisionError.staleFrame
        }
        try checkFrameAge(frame)
        if let sourceID, frame.sourceID != sourceID { throw PhoneVisionError.sourceChanged }
        guard !frame.sourceID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              (1...8_192).contains(frame.pixelWidth), (1...8_192).contains(frame.pixelHeight),
              frame.pixelWidth * frame.pixelHeight <= 32_000_000,
              frame.pixelWidth == frame.cgImage.width, frame.pixelHeight == frame.cgImage.height,
              !frame.jpegData.isEmpty, frame.jpegData.count <= 10_000_000,
              let imageSource = CGImageSourceCreateWithData(frame.jpegData as CFData, nil),
              CGImageSourceGetStatusAtIndex(imageSource, 0) == .statusComplete else {
            throw PhoneVisionError.unavailable("The iPhone screen image was invalid. Reconnect its USB screen and try again.")
        }
    }

    private func checkFrameAge(_ frame: PhoneScreenFrame) throws {
        let age = Date().timeIntervalSince(frame.capturedAt)
        guard age.isFinite, age >= -5, age <= 120 else { throw PhoneVisionError.staleFrame }
    }

    private enum InputFingerprint: Equatable {
        case action(PhonePromptAction)
        case wait
    }

    static func hasCleanupSweep(_ steps: [PhoneVisionStep]) -> Bool {
        var left = false, right = false
        for step in steps.reversed() {
            switch step.input {
            case .swipe(.left): left = true
            case .swipe(.right): right = true
            case .drag(let x, let y, let endX, let endY),
                 .timedDrag(let x, let y, let endX, let endY, _, _, _):
                guard abs(endY - y) < 0.15, abs(endX - x) > 0.3 else { return false }
                if endX < x { left = true } else { right = true }
            default: return false
            }
            guard step.afterFrame != nil || step.screenChanged != nil else { return false }
            if left && right { return true }
        }
        return false
    }

    private func checkRepeatedInput(_ input: InputFingerprint, pixels: [UInt8],
                                    previousInput: inout InputFingerprint?, previousPixels: inout [UInt8]?,
                                    repeatedInputs: inout Int) throws {
        if let previousInput, Self.similarInput(previousInput, input),
           let previousPixels, Self.sameScreen(previousPixels, pixels) {
            repeatedInputs += 1
        } else {
            repeatedInputs = 1
        }
        previousInput = input
        previousPixels = pixels
        guard repeatedInputs < 3 else {
            throw PhoneVisionError.unavailable("The same action didn’t change the phone’s screen. Check the connection and screen before trying again.")
        }
    }

    private static func similarInput(_ lhs: InputFingerprint, _ rhs: InputFingerprint) -> Bool {
        switch (lhs, rhs) {
        case (.action(.tap(let x, let y)), .action(.tap(let a, let b))):
            return abs(x - a) <= 0.035 && abs(y - b) <= 0.035
        default: return lhs == rhs
        }
    }

    private static func screenFingerprint(_ image: CGImage) -> [UInt8] {
        var pixels = [UInt8](repeating: 0, count: 32 * 64)
        pixels.withUnsafeMutableBytes { bytes in
            guard let context = CGContext(data: bytes.baseAddress, width: 32, height: 64, bitsPerComponent: 8,
                bytesPerRow: 32, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return }
            context.interpolationQuality = .low
            context.draw(image, in: CGRect(x: 0, y: 0, width: 32, height: 64))
        }
        return pixels
    }

    private static func sameScreen(_ lhs: [UInt8], _ rhs: [UInt8]) -> Bool {
        guard lhs.count == rhs.count, !lhs.isEmpty else { return false }
        var changed = 0
        for index in (32 * 4)..<(32 * 60) {
            if abs(Int(lhs[index]) - Int(rhs[index])) > 18 { changed += 1 }
        }
        return Double(changed) / Double(32 * 56) < 0.025
    }

    private func description(of action: PhonePromptAction) -> String {
        switch action {
        case .home: "Go Home"
        case .tap(let x, let y): "Tap at \(Int(x * 100))%, \(Int(y * 100))%"
        case .swipe(let direction): "Swipe \(direction.rawValue)"
        case .drag(let x1, let y1, let x2, let y2): "Drag from \(Int(x1 * 100))%, \(Int(y1 * 100))% to \(Int(x2 * 100))%, \(Int(y2 * 100))%"
        case .typeText: "Type text"
        case .doubleTap(let x, let y): "Double tap at \(Int(x * 100))%, \(Int(y * 100))%"
        case .longPress(let x, let y, let seconds): "Long press at \(Int(x * 100))%, \(Int(y * 100))% for \(seconds)s"
        case .timedDrag(let x, let y, let endX, let endY, let duration, let press, let hold):
            "Drag \(Int(x * 100))%, \(Int(y * 100))% → \(Int(endX * 100))%, \(Int(endY * 100))% (\(duration)s, holds \(press)s/\(hold)s)"
        case .press(let key): "Press \(key.rawValue)"
        case .openApp(let name): "Open \(name)"
        case .search: "Search"
        }
    }

    private func beforeDeadline<Value: Sendable>(
        _ deadline: ContinuousClock.Instant,
        operation: @escaping @MainActor () async throws -> Value
    ) async throws -> Value {
        let pending = PendingResult<Value>()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            guard ContinuousClock.now < deadline else { throw PhoneVisionError.limitReached }
            return try await withCheckedThrowingContinuation { continuation in
                pending.continuation = continuation
                pending.operation = Task { @MainActor in
                    do {
                        try Task.checkCancellation()
                        let value = try await operation()
                        try Task.checkCancellation()
                        pending.finish(.success(value))
                    } catch {
                        pending.finish(.failure(Task.isCancelled ? CancellationError() : error))
                    }
                }
                pending.timer = Task { @MainActor in
                    do {
                        try await Task.sleep(until: deadline, clock: .continuous)
                        pending.finish(.failure(PhoneVisionError.limitReached))
                    } catch { }
                }
            }
        } onCancel: {
            Task { @MainActor in pending.finish(.failure(CancellationError())) }
        }
    }

    @MainActor private final class PendingResult<Value: Sendable> {
        var continuation: CheckedContinuation<Value, Error>?
        var operation: Task<Void, Never>?
        var timer: Task<Void, Never>?

        func finish(_ result: Result<Value, Error>) {
            guard let continuation else { return }
            self.continuation = nil
            operation?.cancel()
            timer?.cancel()
            operation = nil
            timer = nil
            continuation.resume(with: result)
        }
    }
}
