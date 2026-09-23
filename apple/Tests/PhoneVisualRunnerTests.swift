import Foundation

@main @MainActor enum PhoneVisualRunnerTests {
    typealias T = TransactionTestSupport
    static func main() async throws {
        try await deterministicReplay()
        try await locatorCannotChangeProgram()
        try await staleAndChangedSources()
        try await writeAheadAndVerification()
        try await uncertainAndUnavailable()
        try await cancellationAndDeadlines()
        try await boundsAndGraphValidation()
        try await warmUpContracts()
        try await namedRecoveryBudgets()
        try await builtInLaunchAndPhaseCompilation()
        try await warmUpLaunchUsesFixedAccount()
        try await diagnostic()
        print("Transaction runner tests passed (replay, locator isolation, frames, durability, uncertainty, cancellation, budgets, warm-up, diagnostic)")
    }
    static func deterministicReplay() async throws {
        var traces: [[String]] = []
        for workflow: DeviceWorkflow? in [nil, .createContent] {
            let rig = T.Rig()
            _ = try await rig.run(workflow: workflow)
            try T.expect(rig.actions == [.home] && rig.captures == 2, "Input was not independently verified")
            try T.expect(rig.locatorCalls == 0 && rig.compileGoals.count == 1, "Execution replanned")
            traces.append(rig.trace)
        }
        try T.expect(traces[0] == traces[1], "Agent and Stage have different execution semantics")
    }
    static func locatorCannotChangeProgram() async throws {
        for decision: PhoneVisionDecision in [.finished("Done"), .wait(seconds: 1, reason: "wait"), .action(.home, reason: "substitute"), .action(.tap(-1, 0), reason: "invalid")] {
            let rig = T.Rig(); rig.plan = T.plan(command: .init(kind: .tap, value: "Profile tab", destination: "", seconds: 0))
            rig.locate = { _, _, history in
                try T.expect(history.isEmpty, "Locator received old planning history")
                return decision
            }
            try await T.rejects { _ = try await rig.run() }
            try T.expect(rig.actions.isEmpty, "Locator changed operation or declared completion")
        }
        let rig = T.Rig(); rig.plan = T.plan(command: .init(kind: .typeText, value: "fixed text", destination: "", seconds: 0))
        _ = try await rig.run()
        try T.expect(rig.actions == [.typeText("fixed text")] && rig.locatorCalls == 0, "Typed payload was not frozen")
    }
    static func staleAndChangedSources() async throws {
        for mode in ["stale", "malformed", "source", "duplicate"] {
            let rig = T.Rig(); let id = UUID()
            rig.captureOverride = { after in
                try T.frame(after: after, id: mode == "duplicate" ? id : UUID(),
                    source: mode == "source" && rig.captures > 1 ? "Other phone" : "Phone",
                    stale: mode == "stale", malformed: mode == "malformed")
            }
            try await T.rejects { _ = try await rig.run() }
            try T.expect(rig.actions.count == (["source", "duplicate"].contains(mode) ? 1 : 0), "Invalid screen authorized input")
        }
    }
    static func writeAheadAndVerification() async throws {
        let rig = T.Rig()
        try await T.rejects {
            _ = try await rig.run { checkpoint in
                if checkpoint.status == .dispatching { throw CocoaError(.fileWriteUnknown) }
            }
        }
        try T.expect(rig.actions.isEmpty, "Journal failure allowed dispatch")
        let pending = T.Rig(); pending.classifyOverride = { question in question.id.hasSuffix(".verify") ? "failed" : "go" }
        try await T.rejects { _ = try await pending.run() }
        try T.expect(pending.actions == [.home], "Failed verification retried input")
        let success = T.Rig(); _ = try await success.run()
        try T.expect(success.trace.firstIndex(of: "savePlan")! < success.trace.firstIndex(of: "perform")!, "Plan was not saved first")
        try T.expect(success.trace.firstIndex(of: "dispatching")! < success.trace.firstIndex(of: "perform")!, "No write-ahead dispatch record")
        try T.expect(success.trace.last == "completed", "No durable completion")
    }
    static func uncertainAndUnavailable() async throws {
        let rig = T.Rig(); rig.classifyOverride = { _ in nil }
        try await T.rejects { _ = try await rig.run() }
        try T.expect(rig.actions.isEmpty && rig.captures == 3, "Uncertainty was not bounded")
        let missing = PhoneVisualRunner(capture: { try T.frame(after: $0) }, decide: { _, _, _ in .finished("bypass") }, perform: { _ in throw T.Failure.assertion("Fallback dispatched") }, blockedReason: { nil })
        try await T.rejects { _ = try await missing.run(goal: "go home", onProgress: { _ in }, onStep: { _ in }) }
        let failed = T.Rig(); failed.classifyOverride = { _ in throw CocoaError(.fileReadUnknown) }
        try await T.rejects { _ = try await failed.run() }
        try T.expect(failed.actions.isEmpty, "Classifier failure used planner fallback")
    }
    static func cancellationAndDeadlines() async throws {
        for stage in ["compile", "classify", "locate"] {
            let rig = T.Rig(); let gate = T.Gate()
            if stage == "compile" { rig.compileOverride = { _, _ in await gate.wait(); return rig.plan } }
            if stage == "classify" { rig.classifyOverride = { _ in await gate.wait(); return "go" } }
            if stage == "locate" {
                rig.plan = T.plan(command: .init(kind: .tap, value: "Profile", destination: "", seconds: 0))
                rig.locate = { _, _, _ in await gate.wait(); return .action(.tap(0.5, 0.5), reason: "late") }
            }
            let task = Task { try await rig.run() }
            try await T.until { gate.waiting }; task.cancel()
            try await T.rejects { _ = try await task.value }
            gate.release()
            await Task.yield()
            try T.expect(rig.actions.isEmpty, "Late \(stage) callback dispatched")
        }
        let rig = T.Rig(); let gate = T.Gate(); rig.duration = 0.05
        rig.classifyOverride = { _ in await gate.wait(); return "go" }
        try await T.rejects { _ = try await rig.run() }; gate.release()
        try T.expect(rig.actions.isEmpty, "Expired classification dispatched")
        let disconnected = T.Rig()
        disconnected.classifyOverride = { _ in disconnected.blocked = "Disconnected"; return "go" }
        try await T.rejects { _ = try await disconnected.run() }
        try T.expect(disconnected.actions.isEmpty, "Disconnection before dispatch was ignored")
    }
    static func boundsAndGraphValidation() async throws {
        for invalid in [T.plan(next: "missing"), T.plan(maximumVisits: 0), T.plan(next: "start"), T.plan(command: .init(kind: .swipe, value: "diagonal", destination: "", seconds: 0))] {
            let rig = T.Rig(); rig.plan = invalid
            try await T.rejects { _ = try await rig.run() }
            try T.expect(rig.actions.isEmpty && rig.captures == 0, "Invalid graph ran")
        }
        let rig = T.Rig(); rig.stepLimit = 1
        try await T.rejects { _ = try await rig.run() }
        try T.expect(rig.actions.count == 1, "Run budget was ignored")
        let looping = T.Rig()
        looping.plan = .init(version: 1, phases: [.init(id: "task", entry: "start", states: [.init(id: "start", maximumVisits: 2, branches: [
            .init(id: "go", condition: "Still loading", command: nil, expected: "", next: "start"),
            .init(id: "done", condition: "Ready", command: nil, expected: "", next: "$done")])])])
        try await T.rejects { _ = try await looping.run() }
        try T.expect(looping.questions.count == 2 && looping.actions.isEmpty, "State budget was ignored")
    }
    static func warmUpContracts() async throws {
        let script = WarmUpScript(network: .tikTok, activity: .post, itemLimit: 1, duration: 300)
        func plan() -> PhoneTransactionPlan {
            .init(version: 1, phases: script.steps.map { step in
                T.plan(command: step.id == .submit ? .init(kind: .tap, value: "Post", destination: "", seconds: 0) : nil, phase: step.id.rawValue).phases[0]
            })
        }
        let rig = T.Rig(); rig.plan = plan()
        var checkpoints: [PhoneTransactionCheckpoint] = []
        _ = try await rig.run(workflow: .warmUp, script: script) { checkpoints.append($0) }
        try T.expect(rig.actions == [.tap(0.5, 0.5)], "Warm-up did not submit exactly once")
        try T.expect(checkpoints.last?.phase == "verifySubmission" && checkpoints.last?.status == .completed, "Submission skipped verification phase")
        for outcome: WarmUpAccountDecision.Outcome in [.mismatch, .signedOut, .unreadable] {
            let denied = T.Rig(); denied.plan = plan(); denied.accountOutcome = outcome
            try await T.rejects { _ = try await denied.run(workflow: .warmUp, script: script) }
            try T.expect(denied.actions.isEmpty, "Account guard allowed engagement")
        }
        let duplicate = T.Rig(); duplicate.plan = .init(version: 1, phases: plan().phases.map { phase in
            phase.id == "verifySubmission" ? T.plan(command: .init(kind: .tap, value: "Post", destination: "", seconds: 0), phase: phase.id).phases[0] : phase
        })
        try await T.rejects { _ = try await duplicate.run(workflow: .warmUp, script: script) }
        try T.expect(duplicate.actions.isEmpty, "Verification phase allowed another submit")
        let watch = WarmUpScript(network: .tikTok, activity: .watch, itemLimit: 1, duration: 300)
        let unreadable = T.Rig(); unreadable.plan = .init(version: 1, phases: watch.steps.map { T.plan(command: nil, phase: $0.id.rawValue).phases[0] })
        try await T.rejects { _ = try await unreadable.run(workflow: .warmUp, script: watch) }
        try T.expect(unreadable.actions.isEmpty, "Watch was counted without measured playback evidence")
    }
    static func namedRecoveryBudgets() async throws {
        let script = WarmUpScript(network: .tikTok, activity: .post, itemLimit: 1, duration: 300)
        for terminal in [false, true] {
            let rig = T.Rig()
            rig.plan = .init(version: 1, phases: script.steps.map { step in
                guard step.id == .prepareSubmission else { return T.plan(command: nil, phase: step.id.rawValue).phases[0] }
                return .init(id: step.id.rawValue, entry: "start", states: [.init(id: "start", maximumVisits: 10, branches: [
                    .init(id: "search-not-focused", condition: "The search field is not focused", command: .init(kind: .tap, value: "Search field", destination: "", seconds: 0), expected: "Search field is focused", next: "start"),
                    .init(id: "go", condition: "Draft ready", command: nil, expected: "", next: "$done")])])
            })
            rig.failure = .init(stepID: "prepareSubmission", failureModeID: "search-not-focused", uncertain: false,
                terminal: terminal, detection: "Field not focused", recovery: "Focus field", evidence: "Field not focused",
                probabilities: [:], margin: 1, threshold: 0.12, promptHash: "fixture")
            try await T.rejects { _ = try await rig.run(workflow: .warmUp, script: script) }
            try T.expect(rig.actions.count == (terminal ? 0 : 2), "Named recovery exceeded contract budget or terminal failure sent input")
        }
        let absent = T.Rig()
        absent.plan = .init(version: 1, phases: script.steps.map { T.plan(command: nil, phase: $0.id.rawValue).phases[0] })
        absent.failure = .init(stepID: "prepareSubmission", failureModeID: "missing-recovery", uncertain: false,
            terminal: false, detection: "Missing", recovery: "Missing", evidence: "Missing", probabilities: [:], margin: 1, threshold: 0.12, promptHash: "fixture")
        try await T.rejects { _ = try await absent.run(workflow: .warmUp, script: script) }
        try T.expect(absent.actions.isEmpty && absent.locatorCalls == 0, "Missing saved recovery fell back to planner")
    }
    static func builtInLaunchAndPhaseCompilation() async throws {
        let plan = try PhoneTransactionCompiler.builtIn(goal: "open tiktok", script: nil)!
        let rig = T.Rig(); rig.plan = plan
        var visualQuestions: [String] = []
        rig.observeOverride = { _, question in
            visualQuestions.append(question)
            return .init(state: visualQuestions.count == 3 ? .foregroundApp : .home,
                appCardsVisible: false, evidence: visualQuestions.count == 3 ? "TikTok is open." : "Home Screen with a TikTok icon in the Dock.")
        }
        rig.classifyOverride = { question in
            if question.id.hasSuffix(".verify") { return "confirmed" }
            return question.id == "openApp.start" ? "home" : "present"
        }
        _ = try await rig.run()
        try T.expect(rig.actions == [.tap(0.5, 0.5)] && rig.captures == 3, "Home Screen launch path stopped or skipped verification")
        try T.expect(rig.questions[1].question == plan.phases[0].states[1].question,
            "Runner discarded the state's specific classification question")
        try T.expect(visualQuestions.count == 3 && visualQuestions[1] == plan.phases[0].states[1].question
            && visualQuestions[2].contains("tiktok app is open"), "Screenshot inspection did not follow the current condition and postcondition")
        let unchanged = T.Rig(); unchanged.plan = plan
        unchanged.classifyOverride = rig.classifyOverride
        try await T.rejects { _ = try await unchanged.run() }
        try T.expect(unchanged.actions.count == 1 && unchanged.captures == 5,
            "Unchanged Home Screen falsely confirmed launch or retried the tap")
        let script = WarmUpScript(network: .tikTok, activity: .watch, itemLimit: 1, duration: 300)
        var inFlight = 0, peak = 0
        var progress: [String] = []
        let compiled = try await PhoneTransactionCompiler.compilePhases(script: script, progress: { progress.append($0) }) { step in
            inFlight += 1; peak = max(peak, inFlight)
            defer { inFlight -= 1 }
            try await Task.sleep(for: .milliseconds(step.id == .account ? 40 : 5))
            return T.plan(command: nil, phase: step.id.rawValue)
        }
        try T.expect(compiled.phases.map(\.id) == script.steps.map { $0.id.rawValue }, "Concurrent compilation reordered script steps")
        try T.expect(peak == 3 && progress.count == script.steps.count, "Compilation was not bounded or lacked progress")
        try await T.rejects {
            _ = try await PhoneTransactionCompiler.compilePhases(script: script, progress: { _ in }) { _ in
                T.plan(command: nil, phase: "wrong")
            }
        }
    }
    static func diagnostic() async throws {
        let rig = T.Rig(); rig.inspectOverride = { _ in .init(state: .appSwitcher, appCardsVisible: true, evidence: "Cards") }
        _ = try await rig.runner().testAppSwitcher(onProgress: { _ in }, onStep: { _ in })
        try T.expect(rig.actions == [.press(.appSwitcher)] && rig.captures == 2 && rig.compileGoals.isEmpty, "Fixed diagnostic regressed")
    }

    static func warmUpLaunchUsesFixedAccount() async throws {
        for network in WarmUpScript.Network.allCases {
            let script = WarmUpScript(network: network, activity: .watch, itemLimit: 1, duration: 300)
            let plan = try await PhoneTransactionCompiler.compilePhases(script: script, progress: { _ in }) { step in
                try T.expect(step.id != .account, "Provider was asked to regenerate account navigation")
                return T.plan(command: nil, phase: step.id.rawValue)
            }
            try T.expect(plan.phases[0] == PhoneTransactionCompiler.accountPhase(script: script), "Warm-up did not save the fixed account phase")
        }
        let script = WarmUpScript(network: .tikTok, activity: .watch, itemLimit: 1, duration: 300)
        let account = try PhoneTransactionCompiler.accountPhase(script: script)
        func plan(_ first: PhoneTransactionPlan.Phase) -> PhoneTransactionPlan {
            .init(version: 1, phases: [first] + script.steps.dropFirst().map { T.plan(command: nil, phase: $0.id.rawValue).phases[0] })
        }
        let rig = T.Rig(); rig.plan = plan(account); rig.accountOutcome = .mismatch
        rig.observeOverride = { _, _ in
            .init(state: rig.actions.isEmpty ? .home : .foregroundApp, appCardsVisible: false,
                evidence: rig.actions.isEmpty ? "Home Screen with TikTok in the Dock." : "TikTok is open.")
        }
        rig.onPerform = { _ in if rig.actions.count == 2 { rig.accountOutcome = .matches } }
        rig.classifyOverride = { question in
            if question.id.hasSuffix(".verify") { return "confirmed" }
            switch question.id {
            case "account.start":
                try T.expect(question.options.map(\.id) == ["home", "app", "blocked", "unknown"],
                    "Screen filtering changed the saved classification alternatives")
                try T.expect(!question.evidence.contains("OCR:"), "Empty OCR diluted the visual screen evidence")
                return "home"
            case "account.launcher":
                try T.expect(!question.evidence.contains("Account:"), "Unrelated account status biased icon classification")
                return "present"
            case "account.profile": return "profile"
            case "account.verifyAccount": throw T.Failure.assertion("Exact account check was sent to a second generic classifier")
            default: throw CancellationError()
            }
        }
        try await T.rejects { _ = try await rig.run(workflow: .warmUp, script: script) }
        try T.expect(rig.actions.count == 2 && rig.actions.allSatisfy { if case .tap = $0 { true } else { false } },
            "Warm-up did not launch from Dock and open Profile with exactly two taps")
        try T.expect(rig.questions.contains { $0.id == "search.start" }, "Verified account did not advance to search")
        try T.expect(rig.accountCalls == 1, "Feed creators were read as the signed-in account before opening Profile")

        let failedSearch = T.Rig(); failedSearch.plan = plan(account); failedSearch.accountOutcome = .unreadable
        failedSearch.classifyOverride = { question in
            if question.id.hasSuffix(".verify") { return "confirmed" }
            return question.id == "account.start" ? "home" : "absent"
        }
        try await T.rejects { _ = try await failedSearch.run(workflow: .warmUp, script: script) }
        try T.expect(failedSearch.actions == [.press(.search)], "Unopened Spotlight allowed typing or resent Search")

        let closedSearch = T.Rig(); closedSearch.plan = plan(account); closedSearch.accountOutcome = .unreadable
        closedSearch.classifyOverride = failedSearch.classifyOverride
        closedSearch.observeOverride = { _, _ in
            .init(state: closedSearch.captures == 3 ? .spotlight : .home, appCardsVisible: false, evidence: "Current screen")
        }
        try await T.rejects { _ = try await closedSearch.run(workflow: .warmUp, script: script) }
        try T.expect(closedSearch.actions == [.press(.search)] && closedSearch.captures == 4,
            "Query ignored its fresh-frame Spotlight precondition")

        let wrongSurface = T.Rig(); wrongSurface.plan = plan(account)
        wrongSurface.classifyOverride = { _ in "app" }
        try await T.rejects { _ = try await wrongSurface.run(workflow: .warmUp, script: script) }
        try T.expect(wrongSurface.actions.isEmpty, "Classifier overrode the Home Screen evidence and dispatched an app-only command")
    }
}
