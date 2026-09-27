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
    private let classifyFailure: ((PhoneScreenFrame, PhoneScreenObservation, WarmUpScript, WarmUpScript.StepID, String?) async throws -> WarmUpFailureDecision?)?
    private let stepBudget: ((WarmUpScript, WarmUpScript.StepID) -> WarmUpStepBudget?)?
    private let compile: ((String, WarmUpScript?, @escaping @MainActor (String) -> Void) async throws -> PhoneTransactionPlan)?
    private let classify: ((PhoneTransactionQuestion) async throws -> PhoneTransactionAnswer)?
    private let recordDecision: ((SemanticIfCaptureRecord, Data) -> Void)?
    private var isRunning = false
    private var sessionDeadline: ContinuousClock.Instant?

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
         classifyFailure: ((PhoneScreenFrame, PhoneScreenObservation, WarmUpScript, WarmUpScript.StepID, String?) async throws -> WarmUpFailureDecision?)? = nil,
         stepBudget: ((WarmUpScript, WarmUpScript.StepID) -> WarmUpStepBudget?)? = nil,
         compile: ((String, WarmUpScript?, @escaping @MainActor (String) -> Void) async throws -> PhoneTransactionPlan)? = nil,
         classify: ((PhoneTransactionQuestion) async throws -> PhoneTransactionAnswer)? = nil,
         recordDecision: ((SemanticIfCaptureRecord, Data) -> Void)? = nil) {
        self.compile = compile
        self.classify = classify
        self.recordDecision = recordDecision
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
        let captureRun = SemanticIfCaptureRecord.run(startedAt: Date(), script: warmUpScript, workflow: workflow)
        var captured = 0
        let preparationDeadline = ContinuousClock.now + .seconds(min(240, maximumDuration))
        try checkAvailability(deadline: preparationDeadline)
        onProgress("Preparing workflow…")
        let plan = try await beforeDeadline(preparationDeadline) { try await compile(goal, warmUpScript, onProgress) }
        try plan.validate(script: warmUpScript)
        try checkAvailability(deadline: preparationDeadline)
        let deadline = ContinuousClock.now + .seconds(duration)
        sessionDeadline = deadline
        defer { sessionDeadline = nil }
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
        var pendingPixels: [UInt8]?
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
        var dismissals = 0
        var mismatch: String?
        func resetPhase() {
            stateID = plan.phases[phaseIndex].entry
            pending = nil
            pendingInput = nil
            pendingEvidence = ""
            pendingIdentity = []
            pendingPixels = nil
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
            pendingPixels = nil
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
                // The executing phase owns the budget: a consume duration skip moves the cursor to advance before its swipe is verified.
                let step = WarmUpScript.StepID(rawValue: phase.id) ?? cursor.step.id
                guard let budget = stepBudget?(cursor.script, step) else { throw PhoneTransactionError.unavailable }
                operationDeadline = min(deadline, phaseStarted + .seconds(budget.maxSeconds))
                guard phaseVisits <= budget.maxPlannerDecisions else {
                    guard step == .open else { throw PhoneVisionError.limitReached }
                    throw PhonePromptPlanningError.needsClarification("No qualifying result was found within this step's \(budget.maxPlannerDecisions) checks. The query and threshold were not changed; check the phone before continuing.")
                }
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
            let signals = PhoneScreenSignal.matching(text.regions, network: warmUpScript?.network)
            let keyboard = observation.keyboardVisible ?? (PhoneWatchChecks.keyboardVisible(in: text) ? true : nil)
            func record(_ question: PhoneTransactionQuestion?, _ source: SemanticIfCaptureRecord.Source,
                        _ selected: String?, _ scores: PhoneTransactionAnswer? = nil) {
                guard let recordDecision else { return }
                captured += 1
                recordDecision(.init(run: captureRun, sequence: captured, capturedAt: frame.capturedAt, phase: phase.id,
                    state: state.id, pending: pending?.id, question: question, source: source, selected: selected,
                    probabilities: scores?.probabilities, margin: scores?.margin, observation: observation,
                    regions: text.regions.map(SemanticIfCaptureRecord.Region.init),
                    signals: PhoneScreenSignal.allCases.filter { signals.contains($0) }), frame.jpegData)
            }
            // An in-app sheet or alert that no branch here handles is closed the way a person would: one safe dismiss tap, then observe again.
            let handlesDialog = state.branches.contains { branch in
                branch.command != nil && branch.requiredScreens?.contains(.dialog) == true && (branch.signal.map { signals.contains($0) } ?? true)
            }
            if observation.state == .dialog, let active = cursor, dismissals < Self.maximumDismissals, submission == nil,
               ![.prepareSubmission, .submit, .verifySubmission].contains(active.step.id), !signals.contains(.passcode),
               pending?.signal != .dismissControl, pending?.expectedScreen != .dialog,
               pending?.expectedSignal.map({ signals.contains($0) }) != true,
               !handlesDialog || (pending != nil && pending?.command?.kind != .wait) {
                let command = PhoneTransactionPlan.Command(kind: .tap, value: PhoneTransactionCompiler.interruptTarget, destination: "", seconds: 0)
                let decision = try await beforeDeadline(operationDeadline) { [self] in try await decide(command.locatorRequest, frame, []) }
                if let action = try? command.resolved(using: decision), case .tap(let x, let y) = action,
                   PhoneWatchChecks.safeDismissTap(x: x, y: y, regions: text.regions) {
                    // Only a sheet that has settled is dismissed; one still animating is observed again.
                    try await beforeDeadline(operationDeadline) { try await Task.sleep(for: .seconds(1)) }
                    let settled = try await beforeDeadline(operationDeadline) { [self] in try await capture(Date()) }
                    guard Self.sameScreen(Self.screenFingerprint(frame.cgImage), Self.screenFingerprint(settled.cgImage)) else {
                        after = Date()
                        continue
                    }
                    try DevicePromptPlanner.validate(.init(actions: [action]))
                    try checkRepeatedInput(.action(action), pixels: Self.screenFingerprint(frame.cgImage),
                        previousInput: &previousInput, previousPixels: &previousPixels, repeatedInputs: &repeatedInputs)
                    dismissals += 1
                    record(nil, .deterministic, "dismiss")
                    try checkpoint(.dispatching, branch: "dismiss", input: action.modelInputDescription)
                    onStep(.init(id: UUID(), number: number, action: "Closed a popup",
                        detail: "Observed: \(observation.evidence)", capturedAt: frame.capturedAt, input: action,
                        decisionSource: "Semantic If interrupt"))
                    try checkAvailability(deadline: operationDeadline)
                    try checkFrameAge(frame)
                    try await beforeDeadline(operationDeadline) { [self] in try await perform(action) }
                    try checkpoint(.verifying, branch: "dismiss", input: action.modelInputDescription)
                    try await beforeDeadline(operationDeadline) { try await Task.sleep(for: .seconds(1)) }
                    after = Date()
                    continue
                }
            }
            if pending == nil, let screens = state.requiredScreens, !screens.contains(observation.state) {
                record(nil, .deterministic, nil)
                onStep(.init(id: UUID(), number: number, action: "Unexpected screen",
                    detail: "Observed: \(observation.evidence)", capturedAt: frame.capturedAt))
                try await restart(after: PhonePromptPlanningError.needsClarification(
                    "The screen changed before this workflow step. No input was sent. " + observation.evidence), number: number, frame: frame)
                continue
            }
            // A wait sent no input, so a dialog that interrupts it is handled by observing the same state again.
            if pending?.command?.kind == .wait, observation.state == .dialog, state.requiredScreens?.contains(.dialog) == true {
                record(nil, .deterministic, nil)
                pending = nil
                verificationAttempts = 0
                reused = (frame, observation, text)
                continue
            }
            var context = evidence
            var playbackEvidence: PhonePlaybackEvidence?
            if cursor?.step.id == .consume, cursor?.script.usesVideo == true {
                let measured = playback.observe(text)
                let identity = PhoneWatchChecks.identity(of: observation, text: text, network: warmUpScript?.network)
                let visual = visualPlayback.observe(observation.video, identity: identity, at: frame.capturedAt)
                let result = plan.watchQuery != nil
                    ? PhonePlaybackEvidence(summary: measured.summary + "\n" + visual.summary,
                        replayCandidate: measured.replayCandidate || visual.replayCandidate,
                        durationSeconds: measured.durationSeconds ?? visual.durationSeconds,
                        isAdvancing: measured.isAdvancing || visual.isAdvancing)
                    : measured
                playbackEvidence = result
                sawReplay = sawReplay || result.replayCandidate
                if let limit = cursor?.script.maximumVideoDurationSeconds,
                   dwell.observe(identity: identity, playing: observation.video?.playing, at: frame.capturedAt,
                       duration: result.durationSeconds, limit: limit) {
                    sawReplay = true
                    context += "\nPlayback: the same video played continuously past its full length."
                }
                context += "\nPlayback: \(result.summary)\nMeasured replay in this step: \(sawReplay)."
            }
            var account: WarmUpAccountDecision?
            var failure: WarmUpFailureDecision?
            var owned: String?
            if let cursor {
                if cursor.step.id != .account, plan.watchQuery == nil {
                    context += "\nPhase: \(cursor.step.id.rawValue). Advance already sent: \(cursor.advanceSent). Submission already sent: \(cursor.submissionSent)."
                }
                if cursor.step.id == .account {
                    if state.accountGate == true || !phase.states.contains(where: { $0.accountGate == true }) {
                        guard let classifyAccount else { throw PhoneTransactionError.unavailable }
                        account = try await beforeDeadline(operationDeadline) { try await classifyAccount(frame, observation, cursor.script, goal) }
                        guard let account else { throw PhoneTransactionError.unavailable }
                        // A handle mismatch stops only when a second frame reads the same wrong handle.
                        if account.outcome == .signedOut || (account.outcome == .mismatch && mismatch == account.evidence) {
                            throw PhonePromptPlanningError.needsClarification(account.evidence)
                        }
                        if account.outcome == .mismatch { mismatch = account.evidence }
                        if state.accountGate == true || state.branches.contains(where: { $0.next == "$done" }) {
                            context += "\nAccount: \(account.outcome.rawValue)."
                        }
                    }
                } else if plan.watchQuery == nil, let classifyFailure {
                    owned = Self.runnerFailure(step: cursor.step.id, observation: observation,
                        duration: playbackEvidence?.durationSeconds, limit: cursor.script.maximumVideoDurationSeconds)
                    if owned == nil {
                        let summary = playbackEvidence?.summary
                        failure = try await beforeDeadline(operationDeadline) { try await classifyFailure(frame, observation, cursor.script, cursor.step.id, summary) }
                        guard let failure else { throw PhoneTransactionError.unavailable }
                        if failure.terminal, failure.failureModeID != nil {
                            throw PhonePromptPlanningError.needsClarification(failure.evidence)
                        }
                    }
                    context += "\nFailure: \(owned ?? failure?.failureModeID ?? "none")."
                }
            }
            var question: PhoneTransactionQuestion
            var shortCircuit: String?
            var unoffered = false
            let comparesItem = pending?.command?.kind == .swipe && (phase.id == "consume" || phase.id == "advance")
            if let pending {
                let verificationEvidence = plan.watchQuery != nil && !comparesItem ? evidence : context + "\nBefore input:\n" + pendingEvidence
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
                // so only offer branches the structured screen state, OCR signals, and sign-in controls allow.
                let signInVisible = LayaAccountPrompt.hasSignInControls(text.regions.filter { $0.confidence >= 0.6 }.map(\.text))
                let engagementState = Self.engagementBranch(check: state.check, video: observation.video)
                // A frame without any readable text (a logo splash, a failed OCR pass) cannot gate: Laya decides, but never toward a signal-gated stop.
                let readable = text.regions.contains { $0.confidence >= 0.6 }
                let named = state.app.map { app in
                    state.id == "start" ? PhoneScreenSignal.foregroundApp(app, evidence: observation.checkEvidence ?? observation.evidence)
                        : PhoneScreenSignal.names(app, evidence: observation.checkEvidence ?? observation.evidence, regions: text.regions)
                }
                let branches = state.branches.filter { branch in
                    (branch.requiredScreens?.contains(observation.state) ?? true)
                        && (branch.keyboard == nil || keyboard == nil || branch.keyboard == keyboard)
                        && (branch.id != "login" || signInVisible || (plan.watchQuery == nil && cursor?.step.id != .account))
                        && (branch.signal.map { readable ? signals.contains($0) : branch.next != "$stop" } ?? true)
                        && (!readable || branch.absentSignal.map { !signals.contains($0) } ?? true)
                        && (branch.video.map { $0 == (observation.video != nil) } ?? true)
                        && (branch.named.map { $0 == named } ?? true)
                        && (engagementState.map { $0 == branch.id } ?? true)
                }
                // Taps toggle likes and follows, so engage only on Codex's explicit structured reading.
                guard !branches.isEmpty || state.check == nil, engagementState != nil || (state.check != .like && state.check != .follow) else {
                    record(nil, .deterministic, nil)
                    try await restart(after: PhoneTransactionError.uncertain, number: number, frame: frame)
                    continue
                }
                unoffered = branches.isEmpty
                // The only survivor whose positive signal matched (a visible dismiss control wins over the screen it covers),
                // or a lone survivor of the state's screen partition, skips Laya; never stop without a signal.
                let signaled = readable ? branches.filter { $0.signal != nil } : []
                let dismiss = signaled.filter { $0.signal == .dismissControl }
                let positive = signaled.count == 1 ? signaled.first : dismiss.count == 1 ? dismiss.first : nil
                if state.check == nil || state.check == .query || positive != nil,
                   let only = positive ?? (branches.count == 1 ? branches.first : nil),
                   positive != nil || (only.next != "$stop" && state.branches.allSatisfy { $0.requiredScreens != nil }) {
                    shortCircuit = only.id
                }
                if let engagementState { shortCircuit = engagementState }
                if let owned, let recovery = branches.first(where: { $0.id == owned }), recovery.next != "$stop" {
                    shortCircuit = recovery.id
                }
                question = .init(id: key, evidence: context,
                    options: branches.map { .init(id: $0.id, description: $0.condition) }
                        + [.init(id: "unknown", description: "None of the listed conditions is clearly supported by the current evidence.")],
                    question: state.question ?? "Which condition is clearly supported by the current screen evidence?")
            }
            if pending == nil, let check = state.check,
               let visualQuestion = PhoneWatchChecks.question(id: question.id, check: check, evidence: evidence, video: observation.video) {
                question = visualQuestion
            }
            let verifyingWatchSwipe = plan.watchQuery != nil && warmUpScript?.usesVideo == true && comparesItem
            if verifyingWatchSwipe,
               let visualQuestion = PhoneWatchChecks.question(id: question.id, check: .advance, evidence: evidence, video: observation.video) {
                question = visualQuestion
            }
            let declared = pending.map { $0.expectedVideo != nil || $0.expectedKeyboard != nil || $0.expectedSignal != nil || $0.expectedTab != nil } ?? false
            let verifyingWatchPlayback = plan.watchQuery != nil && pending != nil && state.check == .playback && !verifyingWatchSwipe && !declared
            if verifyingWatchPlayback,
               let visualQuestion = PhoneWatchChecks.question(id: question.id, check: .playback, evidence: evidence, video: observation.video) {
                question = visualQuestion
            }
            if plan.watchQuery != nil, observation.video != nil, question.options.contains(where: { $0.id == "player" }) {
                question = .init(id: question.id, evidence: question.evidence,
                    options: question.options.filter { !["results", "profile"].contains($0.id) }, question: question.question)
            }
            let unmet = pending.map { awaiting in
                awaiting.expectedVideo.map { $0 != (observation.video != nil) } == true
                    || awaiting.expectedKeyboard.map { $0 != (keyboard == true) } == true
                    || awaiting.expectedSignal.map { !signals.contains($0) } == true
                    || awaiting.expectedTab.map { !PhoneWatchChecks.selectsTab($0, in: [observation.checkEvidence, observation.evidence].compactMap { $0 }) } == true
                    || pendingPixels.map { Self.sameScreen($0, Self.screenFingerprint(frame.cgImage)) } == true
                    || (awaiting.named == true && observation.state == .foregroundApp && state.app.map { app in
                        ![observation.checkEvidence, observation.evidence].compactMap { $0 }
                            .contains { PhoneScreenSignal.names(app, evidence: $0, regions: text.regions) } } == true)
            } ?? false
            let decidedCheck: PhoneTransactionPlan.State.Check? = verifyingWatchPlayback ? .playback : pending == nil ? state.check : nil
            let currentIdentity = PhoneWatchChecks.identity(of: observation, text: text, network: warmUpScript?.network)
            let nextPost = comparesItem && plan.watchQuery != nil && (warmUpScript?.usesVideo == false || observation.video != nil)
                && pendingIdentity.count >= 2 && currentIdentity.count >= 2 && !PhoneWatchChecks.sameItem(currentIdentity, pendingIdentity)
            let typedQuery = pending?.command.flatMap { $0.kind == .typeText && ($0.value == plan.watchQuery || cursor?.step.id == .search) ? $0.value : nil }
            let typedVisible = typedQuery.map { PhoneWatchChecks.queryVisible($0, in: text) }
            onProgress("Checking the current screen…")
            var selected: String?
            var source = SemanticIfCaptureRecord.Source.laya
            var scores: PhoneTransactionAnswer?
            if pending == nil, state.accountGate == true {
                guard let account else { throw PhoneTransactionError.unavailable }
                selected = account.outcome == .matches ? "matches" : "unreadable"
                source = .account
                scores = .init(selected: selected, probabilities: account.probabilities, margin: account.margin)
            } else if let failure, failure.uncertain || (pending == nil && failure.failureModeID != nil) {
                selected = failure.uncertain ? nil : failure.failureModeID
                source = .failure
                scores = .init(selected: selected, probabilities: failure.probabilities, margin: failure.margin)
            } else if let shortCircuit {
                selected = shortCircuit
                source = .shortCircuit
            } else if unmet || unoffered {
                source = .deterministic
            } else if pending != nil, state.check == .like || state.check == .follow {
                selected = Self.engagementBranch(check: state.check, video: observation.video).flatMap { $0 == pending?.id ? nil : "confirmed" }
                source = .deterministic
            } else if declared || typedVisible == true || nextPost {
                selected = "confirmed"
                source = .deterministic
            } else if let check = decidedCheck,
                      let answer = PhoneWatchChecks.answer(check: check, video: observation.video, signals: signals,
                          advancing: playbackEvidence?.isAdvancing == true) {
                selected = answer
                source = .deterministic
            } else {
                let currentQuestion = question
                let answer = try await beforeDeadline(operationDeadline) { try await classify(currentQuestion) }
                scores = answer
                selected = answer.selected
                if let answer = selected, !currentQuestion.options.contains(where: { $0.id == answer }) { selected = nil }
            }
            record(question, source, selected, scores)
            if pending == nil, source == .failure || (source == .shortCircuit && selected == owned), let mode = selected {
                if state.branches.contains(where: { $0.id == mode }) {
                    recoveryAttempts[mode, default: 0] += 1
                    guard recoveryAttempts[mode, default: 0] <= WarmUpFailureClassifier.attemptLimit(for: mode) else {
                        throw PhoneTransactionError.uncertain
                    }
                } else { selected = nil }
            }
            if pending == nil, source != .shortCircuit, let check = state.check {
                selected = PhoneWatchChecks.branch(for: selected, check: check, evidence: observation.evidence,
                    duration: playbackEvidence?.durationSeconds, limit: cursor?.script.maximumVideoDurationSeconds,
                    replay: sawReplay, advanceSent: cursor?.advanceSent == true)
                if check == .advance, selected == "alreadySent", !advanceVerified { selected = nil }
            }
            if verifyingWatchSwipe { selected = selected == "player" || selected == "confirmed" ? "confirmed" : nil }
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
                if typedVisible == false { selected = nil }
                if comparesItem {
                    let sameItem = pendingIdentity.count >= 2 && PhoneWatchChecks.sameItem(currentIdentity, pendingIdentity)
                    if sameItem || (plan.watchQuery != nil && (pendingIdentity.count < 2 || currentIdentity.count < 2)) {
                        selected = nil
                    } else if plan.watchQuery != nil, selected == "confirmed" { advanceVerified = true }
                }
                if Self.engagementBranch(check: state.check, video: observation.video) == awaiting.id { selected = nil }
                guard selected == "confirmed", !unmet,
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
                pendingPixels = nil
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
                    // A page still loading reflows its controls under a tap (TikTok's results tabs); wait for it like a person would.
                    if command.kind == .tap, uncertainAttempts < 2,
                       PhoneWatchChecks.loading([observation.checkEvidence, observation.evidence].compactMap { $0 }) {
                        recordUnverifiedObservation()
                        uncertainAttempts += 1
                        try await beforeDeadline(operationDeadline) { try await Task.sleep(for: .seconds(1)) }
                        after = Date()
                        continue
                    }
                    var decision: PhoneVisionDecision?
                    if command.needsLocation {
                        decision = try await beforeDeadline(operationDeadline) { [self] in
                            try await decide(command.locatorRequest, frame, [])
                        }
                    }
                    let action: PhonePromptAction?
                    do {
                        action = try command.resolved(using: decision)
                        // Taps toggle Follow and Subscribe; only the engagement steps may touch them.
                        if case .tap(let x, let y) = action, state.check != .like, state.check != .follow,
                           PhoneWatchChecks.nearFollow(x: x, y: y, regions: text.regions) { throw PhoneTransactionError.invalidLocation }
                    }
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
                        if action == .swipe(.up), phase.id == "consume" || phase.id == "advance" {
                            let identity = PhoneWatchChecks.identity(of: observation, text: text, network: warmUpScript?.network)
                            if plan.watchQuery != nil {
                                guard identity.count >= 2 else {
                                    try await restart(after: PhoneTransactionError.uncertain, number: number, frame: frame)
                                    continue
                                }
                                advanceVerified = false
                            }
                            pendingIdentity = identity
                        }
                        let pixels = Self.screenFingerprint(frame.cgImage)
                        try checkRepeatedInput(.action(action), pixels: pixels,
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
                        try await beforeDeadline(operationDeadline) { [self] in try await perform(dispatchedAction) }
                        pendingPixels = Self.changesScreen(command, check: state.check) ? pixels : nil
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
                        pendingPixels = nil
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
    static let maximumDismissals = 4

    /// Failure modes the runner reads from its own state and the structured observation instead of asking Laya.
    static func runnerFailure(step: WarmUpScript.StepID, observation: PhoneScreenObservation, duration: Int?, limit: Int?) -> String? {
        guard step == .consume else { return nil }
        if [.home, .homeEditing, .appSwitcher, .spotlight].contains(observation.state) { return "navigated-away" }
        if let duration, let limit, duration > limit { return "too-long" }
        return observation.video?.playing == false ? "paused" : nil
    }

    /// Inputs that always redraw most of the screen, so an unchanged frame means the result is still pending.
    static func changesScreen(_ command: PhoneTransactionPlan.Command, check: PhoneTransactionPlan.State.Check?) -> Bool {
        guard check.map({ [.like, .follow, .playback].contains($0) }) != true else { return false }
        switch command.kind {
        case .tap, .doubleTap, .longPress: return true
        case .press: return ["enter", "search", "escape", "appSwitcher", "assistiveTouch"].contains(command.value)
        default: return false
        }
    }

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
        guard ContinuousClock.now < deadline else { throw expired() }
        if let reason = blockedReason() { throw PhoneVisionError.unavailable(reason) }
    }

    /// The whole session's time running out is a normal end for a watch session; a step budget running out is not.
    private func expired() -> PhoneVisionError {
        sessionDeadline.map { ContinuousClock.now >= $0 } == true ? .sessionTimeUp : .limitReached
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
            guard ContinuousClock.now < deadline else { throw expired() }
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
                        pending.finish(.failure(self.expired()))
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
