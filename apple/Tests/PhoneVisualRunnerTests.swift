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
        try await screenSignalGates()
        try await shortCircuitNeverStopsBlind()
        try await deterministicVerification()
        try await nonVideoItems()
        try await captureJournal()
        try await runnerOwnedFailures()
        try await accountRecoveries()
        try await interruptDismissal()
        try await agentGesture()
        print("Transaction runner tests passed (agent gesture, replay, locator isolation, frames, durability, uncertainty, cancellation, budgets, deterministic launcher, account phase, diagnostic, signal gates, short-circuit, postconditions, non-video items, capture journal, runner-owned failures, account recoveries, interrupt dismissal)")
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
        for invalid in [T.plan(next: "missing"), T.plan(maximumVisits: 0), T.plan(next: "start"), T.plan(command: .init(kind: .swipe, value: "diagonal", destination: "", seconds: 0)),
                        single([.init(id: "go", condition: "Ready", command: nil, expected: "", next: "$done", expectedSignal: .resultsTabs)]),
                        single([.init(id: "go", condition: "Ready", command: nil, expected: "", next: "$done", signal: .tabBar, absentSignal: .tabBar)])] {
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
        try T.expect(absent.failureSteps.filter { $0.0 == .prepareSubmission }.count == 3, "A mode without a saved recovery was not retried on fresh frames")
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
        try T.expect(rig.questions.map(\.id) == ["openApp.launcher.verify"] && rig.records.prefix(2).map(\.source) == [.shortCircuit, .shortCircuit]
            && rig.records.prefix(2).map(\.selected) == ["home", "present"], "The Home frame or the named Dock icon still asked Laya")
        try T.expect(visualQuestions.count == 3 && visualQuestions[1] == plan.phases[0].states[1].question
            && visualQuestions[2].contains("tiktok app is open"), "Screenshot inspection did not follow the current condition and postcondition")
        let unchanged = T.Rig(); unchanged.plan = plan
        unchanged.classifyOverride = rig.classifyOverride
        unchanged.observeOverride = { _, _ in .init(state: .home, appCardsVisible: false, evidence: "Home Screen with a TikTok icon in the Dock.") }
        try await T.rejects { _ = try await unchanged.run() }
        try T.expect(unchanged.actions.count == 1 && unchanged.captures == 5,
            "Unchanged Home Screen falsely confirmed launch or retried the tap")
        try await deterministicLauncher()
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
    static func deterministicLauncher() async throws {
        func launch(_ goal: String, evidence: String, spotlight: [(String, Double)], classify: @escaping (PhoneTransactionQuestion) -> String? = {
            $0.id.hasSuffix(".verify") ? "confirmed" : $0.id.hasSuffix(".query") ? "empty" : "installed"
        }) async throws -> T.Rig {
            let plan = try PhoneTransactionCompiler.builtIn(goal: goal, script: nil)!
            let rig = T.Rig(); rig.plan = plan
            rig.observeOverride = { _, _ in
                let searched = rig.actions.contains(.press(.search))
                let opened = rig.actions.last.map { if case .tap = $0 { true } else { false } } == true
                return .init(state: opened ? .foregroundApp : searched ? .spotlight : .home, appCardsVisible: false,
                    evidence: opened ? "\(goal.dropFirst(5)) is open." : searched ? "Spotlight search results." : evidence,
                    keyboardVisible: searched && !opened ? true : nil)
            }
            rig.readTextOverride = { frame, platform in
                .init(sourceID: frame.sourceID, capturedAt: frame.capturedAt, platform: platform,
                    regions: rig.actions.contains(.press(.search)) ? regions(spotlight) : [])
            }
            rig.classifyOverride = { classify($0) }
            do { _ = try await rig.run() } catch is T.Failure { throw T.Failure.assertion("Unexpected test failure") } catch {}
            return rig
        }
        let installed = [("Top Hit", 0.07), ("TikTok", 0.1), ("App Store", 0.2), ("TikTok Studio", 0.24), ("Get", 0.245)]
        let studio = try await launch("open TikTok", evidence: "Home Screen with an empty grid; the Dock holds TikTok Studio and Safari.", spotlight: installed)
        try T.expect(studio.actions.first == .press(.search) && studio.records.contains { $0.state == "launcher" && $0.selected == "absent" && $0.source == .shortCircuit }
            && studio.actions.contains(.typeText("TikTok")) && studio.actions.last == .tap(0.5, 0.5),
            "TikTok Studio in the Dock was launched as TikTok instead of searching Spotlight")
        let x = try await launch("open X", evidence: "Home Screen with an empty grid; the Dock holds X, Xfinity, and Excel.", spotlight: [("X", 0.1), ("Open", 0.1)])
        try T.expect(x.actions == [.press(.search), .press(.selectAll), .typeText("X"), .tap(0.5, 0.5)]
            && x.records.contains { $0.state == "result" && $0.selected == "installed" && $0.source == .shortCircuit },
            "A one-letter app was tapped from the Dock instead of confirmed in Spotlight")
        let negated = try await launch("open TikTok", evidence: "The Dock holds Safari and Mail; the TikTok app icon is not visible on this Home Screen.",
            spotlight: installed)
        try T.expect(negated.actions.first == .press(.search) && negated.records.contains { $0.state == "launcher" && $0.selected == "absent" },
            "An observer sentence saying the icon is absent tapped a TikTok icon instead of searching Spotlight")
        let studioOpened = T.Rig(); studioOpened.plan = try PhoneTransactionCompiler.builtIn(goal: "open TikTok", script: nil)!
        studioOpened.observeOverride = { _, _ in
            studioOpened.actions.isEmpty ? .init(state: .home, appCardsVisible: false, evidence: "Home Screen with TikTok in the Dock.")
                : .init(state: .foregroundApp, appCardsVisible: false, evidence: "TikTok Studio is open on its Home dashboard with analytics.",
                    checkEvidence: "TikTok Studio is open.")
        }
        studioOpened.classifyOverride = { _ in "confirmed" }
        try await T.rejects { _ = try await studioOpened.run() }
        try T.expect(studioOpened.actions == [.tap(0.5, 0.5)] && !studioOpened.questions.contains { $0.id == "openApp.launcher.verify" }
            && studioOpened.records.filter { $0.pending == "present" }.allSatisfy { $0.source == .deterministic && $0.selected == nil },
            "A sibling app such as TikTok Studio confirmed the TikTok launch")
        let store = try await launch("open TikTok", evidence: "Home Screen with an empty grid and a Dock.",
            spotlight: [("TikTok", 0.1), ("Videos, Music & Live Streams", 0.125), ("Get", 0.11)])
        try T.expect(store.actions.filter { if case .tap = $0 { true } else { false } }.isEmpty
            && store.records.last?.selected == "missing" && store.records.last?.source == .shortCircuit,
            "An App Store download row was tapped or the missing stop needed Laya")
        let alert = T.Rig(); alert.plan = try PhoneTransactionCompiler.builtIn(goal: "open TikTok", script: nil)!
        alert.observeOverride = { _, _ in
            .init(state: alert.actions.isEmpty ? .dialog : alert.actions.count == 1 ? .home : .foregroundApp, appCardsVisible: false,
                evidence: alert.actions.isEmpty ? "An alert asks to allow notifications." : "Home Screen with TikTok in the Dock.")
        }
        alert.readTextOverride = { frame, platform in
            .init(sourceID: frame.sourceID, capturedAt: frame.capturedAt, platform: platform,
                regions: alert.actions.isEmpty ? regions([("“TikTok” Would Like to Send You Notifications", 0.4), ("Don't Allow", 0.55), ("Allow", 0.55)]) : [])
        }
        alert.classifyOverride = { $0.id.hasSuffix(".verify") ? "confirmed" : "unknown" }
        _ = try await alert.run()
        try T.expect(alert.records.first?.selected == "alert" && alert.records.first?.source == .shortCircuit && alert.actions.count == 2
            && !alert.questions.contains { $0.id == "openApp.start" }, "A launch alert was not dismissed deterministically before launching")
    }

    static func diagnostic() async throws {
        let rig = T.Rig(); rig.inspectOverride = { _ in .init(state: .appSwitcher, appCardsVisible: true, evidence: "Cards") }
        _ = try await rig.runner().testAppSwitcher(onProgress: { _ in }, onStep: { _ in })
        try T.expect(rig.actions == [.press(.appSwitcher)] && rig.captures == 2 && rig.compileGoals.isEmpty, "Fixed diagnostic regressed")
    }

    static let feedText = regions([("9:41", 0.02), ("For You", 0.065), ("@creator", 0.8), ("A trading setup for today", 0.83),
                                   ("Home", 0.944), ("Friends", 0.944), ("Inbox", 0.944), ("Profile", 0.944)])
    static let profileText = regions([("9:41", 0.02), ("@fixture", 0.18), ("Following", 0.24), ("Followers", 0.24), ("Likes", 0.24),
                                      ("Home", 0.944), ("Friends", 0.944), ("Inbox", 0.944), ("Profile", 0.944)])
    /// TikTok OCR by the inputs sent since the last Home gesture: Home, then the feed after launch, then the profile.
    static func tikTokText(_ rig: T.Rig) -> (PhoneScreenFrame, String) -> PhonePlaybackTracker.Observation {
        { frame, platform in
            let taps = rig.actions.reversed().prefix { $0 != .home }.count
            return .init(sourceID: frame.sourceID, capturedAt: frame.capturedAt, platform: platform,
                regions: taps == 0 ? [] : taps == 1 ? feedText : profileText)
        }
    }

    static func warmUpLaunchUsesFixedAccount() async throws {
        for network in WarmUpScript.Network.allCases {
            let script = WarmUpScript(network: network, activity: .watch, itemLimit: 1, duration: 300)
            let plan = try await PhoneTransactionCompiler.compilePhases(script: script, progress: { _ in }) { step in
                try T.expect(step.id != .account, "Provider was asked to regenerate account navigation")
                return T.plan(command: nil, phase: step.id.rawValue)
            }
            let account = try PhoneTransactionCompiler.accountPhase(script: script)
            try T.expect(plan.phases[0] == account, "Warm-up did not save the fixed account phase")
            let golden = try JSONDecoder().decode(PhoneTransactionPlan.Phase.self, from: Data(contentsOf: URL(fileURLWithPath:
                "Tests/Fixtures/AccountPhase/\(network.rawValue.lowercased())-account-phase.json")))
            try T.expect(account == golden, "\(network.rawValue) account phase differs from its reviewed golden file")
            try T.expect(account.states.first { $0.id == "verifyAccount" }?.question?.contains("signed-in") == false
                && account.states.first { $0.id == "profile" }?.branches.allSatisfy { !$0.condition.contains("signed-in") && !$0.expected.contains("signed-in") } == true,
                "The account phase still primes the observer with 'signed-in'")
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
        rig.readTextOverride = tikTokText(rig)
        rig.onPerform = { _ in if rig.actions.count == 2 { rig.accountOutcome = .matches } }
        rig.classifyOverride = { question in
            switch question.id {
            case "account.launcher.verify":
                try T.expect(!question.evidence.contains("Account:"), "Unrelated account status biased the launch check")
                return "confirmed"
            case "account.start", "account.launcher", "account.profile", "account.profile.verify":
                throw T.Failure.assertion("\(question.id) asked Laya although OCR and screen state decide it")
            case "account.verifyAccount": throw T.Failure.assertion("Exact account check was sent to a second generic classifier")
            default: throw CancellationError()
            }
        }
        try await T.rejects { _ = try await rig.run(workflow: .warmUp, script: script) }
        try T.expect(rig.actions.count == 2 && rig.actions.allSatisfy { if case .tap = $0 { true } else { false } },
            "Warm-up did not launch from Dock and open Profile with exactly two taps")
        try T.expect(rig.questions.map(\.id) == ["account.launcher.verify", "search.start"], "Verified account did not advance to search")
        try T.expect(rig.accountCalls == 1, "Feed creators were read as the signed-in account before opening Profile")
        try T.expect(rig.records.prefix(5).map { "\($0.state).\($0.selected ?? "-")" } == ["start.home", "launcher.present", "launcher.confirmed", "profile.tabs", "profile.confirmed"]
            && rig.records[3].source == .shortCircuit && rig.records[4].source == .deterministic,
            "The tab bar and own-profile OCR did not decide the Profile tap and its verification")

        let deferred = T.Rig(); deferred.plan = plan(account)
        deferred.observeOverride = { _, _ in
            let home = deferred.actions.filter { $0 == .home }.count >= 2
            return .init(state: home ? .home : .foregroundApp, appCardsVisible: false,
                evidence: home ? "Home Screen with TikTok in the Dock." : "Safari is open on a news page.")
        }
        deferred.classifyOverride = { question in
            switch question.id {
            case "account.start.verify": return deferred.actions.count >= 2 ? "confirmed" : "failed"
            default: throw CancellationError()
            }
        }
        try await T.rejects { _ = try await deferred.run(workflow: .warmUp, script: script) }
        try T.expect(deferred.actions == [.home, .home, .tap(0.5, 0.5)] && deferred.records.contains { $0.state == "launcher" && $0.selected == "present" },
            "A Home gesture swallowed by the app stopped the run instead of being resent once")

        let resumed = T.Rig(); resumed.plan = plan(account)
        resumed.observeOverride = { _, _ in .init(state: .foregroundApp, appCardsVisible: false, evidence: "TikTok Profile is open.") }
        resumed.readTextOverride = { frame, platform in
            .init(sourceID: frame.sourceID, capturedAt: frame.capturedAt, platform: platform, regions: profileText)
        }
        resumed.classifyOverride = { _ in throw CancellationError() }
        try await T.rejects { _ = try await resumed.run(workflow: .warmUp, script: script) }
        try T.expect(!resumed.actions.contains(.home) && resumed.records.first.map { $0.state == "start" && $0.selected == "opened" } == true
            && resumed.records.contains { $0.state == "profile" && $0.selected == "profile" } && resumed.accountCalls > 0,
            "An already open TikTok was left through Home instead of checking its profile in place: \(resumed.actions)")

        let recovered = T.Rig(); recovered.plan = plan(account)
        var searchUncertain = 0
        recovered.observeOverride = { _, _ in
            let home = recovered.actions.last.map { $0 == .home } ?? true
            return .init(state: home ? .home : .foregroundApp, appCardsVisible: false,
                evidence: home ? "Home Screen with TikTok in the Dock." : "TikTok is open.")
        }
        recovered.readTextOverride = tikTokText(recovered)
        recovered.classifyOverride = { question in
            if question.id.hasSuffix(".verify") { return "confirmed" }
            switch question.id {
            case "search.start":
                searchUncertain += 1
                return searchUncertain <= 3 ? "unknown" : "go"
            default: return "go"
            }
        }
        try await T.rejects { _ = try await recovered.run(workflow: .warmUp, script: script) }
        try T.expect(recovered.actions.prefix(3) == [.tap(0.5, 0.5), .tap(0.5, 0.5), .home] && recovered.accountCalls == 2
            && recovered.questions.contains { $0.id == "suggestion.start" },
            "An uncertain search did not restart from Home, re-verify the account, and continue past search")

        let store = try WarmUpContractStore(data: Data(contentsOf: URL(fileURLWithPath: "Contracts/warmup-tasks.json")))
        let dismiss = regions([("9:41", 0.02), ("Turn on notifications", 0.55), ("Get notified when friends post", 0.6), ("Turn on", 0.7), ("Not now", 0.76)])
        let splashText = regions([("9:41", 0.02), ("TikTok", 0.48)])
        let screens: [(PhoneScreenObservation.State, String, [PhonePlaybackTracker.TextRegion])] = [
            (.home, "Home Screen with an empty grid; the Dock holds YouTube, TikTok, and Instagram.", []),
            (.home, "Home Screen with an empty grid; the Dock holds YouTube, TikTok, and Instagram.", []),
            (.foregroundApp, "A black screen with the TikTok logo in the center.", splashText),
            (.dialog, "A Turn on notifications sheet over TikTok with Turn on and Not now.", dismiss),
            (.foregroundApp, "The TikTok For You feed with the bottom tab bar.", feedText),
            (.foregroundApp, "The TikTok profile with Following, Followers, and Likes.", profileText)]
        let launched = T.Rig(); launched.plan = plan(account)
        launched.budgetOverride = { store.step(scriptIdentifier: $0.identifier, stepID: $1.rawValue)?.budget }
        func current() -> (PhoneScreenObservation.State, String, [PhonePlaybackTracker.TextRegion]) {
            screens[min(launched.captures, screens.count) - 1]
        }
        launched.observeOverride = { _, _ in .init(state: current().0, appCardsVisible: false, evidence: current().1, checkEvidence: current().1) }
        launched.readTextOverride = { frame, platform in .init(sourceID: frame.sourceID, capturedAt: frame.capturedAt, platform: platform, regions: current().2) }
        launched.classifyOverride = { question in
            guard question.id.hasSuffix(".verify") else { throw CancellationError() }
            return "confirmed"
        }
        try await T.rejects { _ = try await launched.run(workflow: .warmUp, script: script) }
        let decided = launched.records.map { "\($0.state).\($0.selected ?? "-")" }
        try T.expect(decided == ["start.home", "launcher.present", "launcher.confirmed", "profile.splash", "profile.-", "profile.prompt",
                                 "profile.confirmed", "profile.tabs", "profile.confirmed", "verifyAccount.matches"]
            && launched.actions == [.tap(0.5, 0.5), .tap(0.5, 0.5), .tap(0.5, 0.5)] && launched.captures == 7
            && launched.questions.map(\.id) == ["account.launcher.verify", "account.profile.verify", "search.start"],
            "Splash, sheet, and tabs did not lead to the account check within the account budget: \(decided)")

        let blank = T.Rig(); blank.plan = plan(account)
        blank.observeOverride = { _, _ in
            .init(state: blank.actions.isEmpty ? .home : .foregroundApp, appCardsVisible: false,
                evidence: blank.actions.isEmpty ? "Home Screen with TikTok in the Dock." : "A black screen with the TikTok logo in the center.")
        }
        blank.classifyOverride = { question in
            if question.id == "account.profile", blank.questions.filter({ $0.id == "account.profile" }).count > 1 { throw CancellationError() }
            if question.id == "account.profile" {
                try T.expect(question.options.map(\.id) == ["splash", "tabs", "profile", "prompt", "back", "unknown"],
                    "A frame without readable text did not leave splash and tabs to Laya: \(question.options.map(\.id))")
                return "splash"
            }
            if question.id.hasSuffix(".verify") { return "confirmed" }
            throw CancellationError()
        }
        try await T.rejects { _ = try await blank.run(workflow: .warmUp, script: script) }
        try T.expect(blank.actions == [.tap(0.5, 0.5)] && blank.questions.filter { $0.id == "account.profile" }.count == 2
            && !blank.records.contains { $0.selected == "login" }, "A textless splash did not wait, or stopped")

        var dwell = PhoneWatchDwell()
        let start = Date(), video: Set = ["creator:@one", "caption:setup"]
        try T.expect(!dwell.observe(identity: video, playing: true, at: start, duration: nil, limit: 60)
            && !dwell.observe(identity: video, playing: true, at: start + 40, duration: nil, limit: 60)
            && dwell.observe(identity: video, playing: true, at: start + 63, duration: nil, limit: 60),
            "An unmeasurable video was not completed after playing past the duration limit")
        dwell.reset()
        _ = dwell.observe(identity: video, playing: true, at: start, duration: 15, limit: 60)
        try T.expect(dwell.observe(identity: video, playing: true, at: start + 18, duration: 15, limit: 60),
            "A readable 15-second video was not completed after 18 seconds")
        dwell.reset()
        _ = dwell.observe(identity: video, playing: true, at: start, duration: nil, limit: 60)
        _ = dwell.observe(identity: video, playing: false, at: start + 30, duration: nil, limit: 60)
        try T.expect(!dwell.observe(identity: video, playing: true, at: start + 63, duration: nil, limit: 60)
            && !dwell.observe(identity: ["creator:@two", "caption:other"], playing: true, at: start + 200, duration: nil, limit: 60),
            "Paused time or a different video counted toward completion")

        let failedSearch = T.Rig(); failedSearch.plan = plan(account); failedSearch.accountOutcome = .unreadable
        failedSearch.classifyOverride = { question in
            if question.id.hasSuffix(".verify") { return "confirmed" }
            return question.id == "account.start" ? "home" : "absent"
        }
        try await T.rejects { _ = try await failedSearch.run(workflow: .warmUp, script: script) }
        try T.expect(failedSearch.actions == [.press(.search), .home, .press(.search), .home, .press(.search)],
            "Unopened Spotlight allowed typing, resent Search without restarting, or restarted more than twice")

        let closedSearch = T.Rig(); closedSearch.plan = plan(account); closedSearch.accountOutcome = .unreadable
        closedSearch.classifyOverride = failedSearch.classifyOverride
        closedSearch.observeOverride = { _, _ in
            let open = (3...4).contains(closedSearch.captures)
            return .init(state: open ? .spotlight : .home, appCardsVisible: false, evidence: "Current screen", keyboardVisible: open ? true : nil)
        }
        try await T.rejects { _ = try await closedSearch.run(workflow: .warmUp, script: script) }
        try T.expect(Array(closedSearch.actions.prefix(4)) == [.press(.search), .press(.selectAll), .typeText("TikTok"), .home]
            && closedSearch.actions.filter { $0 == .typeText("TikTok") }.count == 1
            && !closedSearch.questions.contains { $0.id == "account.query" || $0.id == "account.replace" },
            "Spotlight did not select any old query before typing on verified frames, or retyped instead of restarting from Home")

        let locked = T.Rig(); locked.plan = plan(account)
        locked.observeOverride = { _, _ in .init(state: .unknown, appCardsVisible: false, evidence: "A passcode keypad is visible.") }
        locked.readTextOverride = { frame, platform in
            .init(sourceID: frame.sourceID, capturedAt: frame.capturedAt, platform: platform,
                regions: regions([("Enter Passcode", 0.22)]) + (1...9).map { .init(text: "\($0)", confidence: 0.99,
                    bounds: CGRect(x: 0.2 + 0.2 * Double(($0 - 1) % 3), y: 0.4 + 0.1 * Double(($0 - 1) / 3), width: 0.05, height: 0.03)) })
        }
        locked.classifyOverride = { _ in throw T.Failure.assertion("A readable passcode keypad asked Laya") }
        try await T.rejects { _ = try await locked.run(workflow: .warmUp, script: script) }
        try T.expect(locked.actions.isEmpty && locked.records.first?.selected == "blocked" && locked.records.first?.source == .shortCircuit,
            "A lock screen received input or a recovery Home gesture")

        let wrongSurface = T.Rig(); wrongSurface.plan = plan(account)
        wrongSurface.classifyOverride = { _ in "app" }
        try await T.rejects { _ = try await wrongSurface.run(workflow: .warmUp, script: script) }
        try T.expect(!wrongSurface.questions.contains { $0.id == "account.start" } && wrongSurface.actions.first == .press(.search)
            && !wrongSurface.actions.contains(.tap(0.5, 0.5)), "Classifier overrode the Home Screen evidence or tapped an unnamed Dock icon")
    }

    static func regions(_ rows: [(String, Double)]) -> [PhonePlaybackTracker.TextRegion] {
        rows.map { .init(text: $0.0, confidence: 0.99, bounds: CGRect(x: 0.2, y: $0.1, width: 0.3, height: 0.016)) }
    }
    static func screen(_ state: PhoneScreenObservation.State = .foregroundApp, keyboard: Bool? = false, video: Bool = false) -> PhoneScreenObservation {
        .init(state: state, appCardsVisible: false, evidence: "Current screen", keyboardVisible: keyboard,
            video: video ? .init(creator: "@creator", caption: "A caption", progress: 0.3, durationSeconds: 20, playing: true) : nil)
    }
    static func single(_ branches: [PhoneTransactionPlan.Branch]) -> PhoneTransactionPlan {
        .init(version: 1, phases: [.init(id: "task", entry: "start", states: [.init(id: "start", maximumVisits: 3, branches: branches)])])
    }

    static func screenSignalGates() async throws {
        let gated = single([
            .init(id: "tabs", condition: "Tabs", command: nil, expected: "", next: "$done", signal: .tabBar),
            .init(id: "splash", condition: "Splash", command: nil, expected: "", next: "$done", absentSignal: .tabBar, video: false),
            .init(id: "player", condition: "Player", command: nil, expected: "", next: "$done", video: true),
            .init(id: "typing", condition: "Typing", command: nil, expected: "", next: "$done", keyboard: true),
            .init(id: "other", condition: "Other", command: nil, expected: "", next: "$done")])
        let clock = regions([("9:41", 0.02), ("Caption line one", 0.5), ("Caption line two", 0.55), ("Caption line three", 0.6), ("Caption four", 0.65)])
        let tabs = regions([("Home", 0.944), ("Friends", 0.944), ("Inbox", 0.944), ("Profile", 0.944)])
        for (ocr, observation, offered) in [(clock, screen(video: true), ["player", "other"]), (clock, screen(keyboard: true), ["splash", "typing", "other"]),
                                            ([], screen(), ["tabs", "splash", "other"])] {
            let rig = T.Rig(); rig.plan = gated
            rig.observeOverride = { _, _ in observation }
            rig.readTextOverride = { frame, platform in .init(sourceID: frame.sourceID, capturedAt: frame.capturedAt, platform: platform, regions: ocr) }
            rig.classifyOverride = { question in
                try T.expect(question.options.map(\.id) == offered + ["unknown"], "Offered \(question.options.map(\.id)), expected \(offered)")
                return "other"
            }
            _ = try await rig.run()
            try T.expect(rig.questions.count == 1 && rig.records.first?.source == .laya, "Signal, video, or keyboard gates were not applied before Laya")
        }
        let signaled = T.Rig(); signaled.plan = gated
        signaled.observeOverride = { _, _ in screen() }
        signaled.readTextOverride = { frame, platform in .init(sourceID: frame.sourceID, capturedAt: frame.capturedAt, platform: platform, regions: tabs) }
        _ = try await signaled.run()
        try T.expect(signaled.questions.isEmpty && signaled.records.first?.selected == "tabs" && signaled.records.first?.source == .shortCircuit,
            "The only survivor with a matched positive signal still asked Laya")
        let stop = single([.init(id: "empty", condition: "No results", command: nil, expected: "", next: "$stop", signal: .noResults),
                           .init(id: "post", condition: "A post", command: nil, expected: "", next: "$done")])
        let textless = T.Rig(); textless.plan = stop
        textless.observeOverride = { _, _ in screen() }
        textless.classifyOverride = { question in
            try T.expect(question.options.map(\.id) == ["post", "unknown"], "A textless frame offered a signal-gated stop")
            return "post"
        }
        _ = try await textless.run()
        let script = WarmUpScript(network: .tikTok, activity: .watch, itemLimit: 1, duration: 300)
        let account = PhoneTransactionPlan.Phase(id: "account", entry: "start", states: [.init(id: "start", maximumVisits: 3, branches: [
            .init(id: "profile", condition: "Profile", command: nil, expected: "", next: "$done"),
            .init(id: "login", condition: "A login screen", command: nil, expected: "", next: "$stop")])])
        for signIn in [false, true] {
            let rig = T.Rig()
            rig.plan = .init(version: 1, phases: [account] + script.steps.dropFirst().map { T.plan(command: nil, phase: $0.id.rawValue).phases[0] })
            rig.observeOverride = { _, _ in screen() }
            rig.readTextOverride = { frame, platform in
                .init(sourceID: frame.sourceID, capturedAt: frame.capturedAt, platform: platform, regions: signIn ? regions([("Log in", 0.5)]) : [])
            }
            rig.classifyOverride = { question in
                try T.expect(question.options.map(\.id) == (signIn ? ["profile", "login", "unknown"] : ["profile", "unknown"]),
                    "The account phase offered the login stop without visible sign-in controls")
                throw CancellationError()
            }
            try await T.rejects { _ = try await rig.run(workflow: .warmUp, script: script) }
            try T.expect(rig.questions.count == 1, "Account phase was not classified")
        }
    }

    static func shortCircuitNeverStopsBlind() async throws {
        let partition = single([
            .init(id: "blocked", condition: "Locked", command: nil, expected: "", next: "$stop", requiredScreens: [.dialog, .unknown]),
            .init(id: "app", condition: "An app", command: nil, expected: "", next: "$done", requiredScreens: [.foregroundApp])])
        let open = T.Rig(); open.plan = partition
        open.observeOverride = { _, _ in screen() }
        open.classifyOverride = { _ in throw T.Failure.assertion("A partitioned app frame asked Laya") }
        _ = try await open.run()
        try T.expect(open.questions.isEmpty && open.records.map(\.source) == [.shortCircuit] && open.records.first?.selected == "app",
            "A single partitioned survivor was not selected deterministically")
        let alert = T.Rig(); alert.plan = partition
        alert.observeOverride = { _, _ in screen(.dialog) }
        alert.classifyOverride = { question in
            try T.expect(question.options.map(\.id) == ["blocked", "unknown"], "A stop branch was not left to Laya")
            return nil
        }
        try await T.rejects { _ = try await alert.run() }
        try T.expect(alert.questions.count == 3 && !alert.records.contains { $0.source == .shortCircuit },
            "A benign dialog short-circuited into a terminal stop")
        let locked = T.Rig()
        locked.plan = single([
            .init(id: "passcode", condition: "Locked", command: nil, expected: "", next: "$stop", signal: .passcode),
            .init(id: "app", condition: "An app", command: nil, expected: "", next: "$done", requiredScreens: [.foregroundApp])])
        locked.observeOverride = { _, _ in screen(.unknown) }
        locked.readTextOverride = { frame, platform in
            .init(sourceID: frame.sourceID, capturedAt: frame.capturedAt, platform: platform, regions: regions([("Enter Passcode", 0.2)]))
        }
        try await T.rejects { _ = try await locked.run() }
        try T.expect(locked.questions.isEmpty && locked.actions.isEmpty && locked.records.first?.source == .shortCircuit
            && locked.records.first?.selected == "passcode", "A positive passcode signal did not stop deterministically")
    }

    static func deterministicVerification() async throws {
        let tap = PhoneTransactionPlan.Command(kind: .tap, value: "Target", destination: "", seconds: 0)
        func verify(_ branch: PhoneTransactionPlan.Branch, observation: PhoneScreenObservation = screen(),
                    ocr: [PhonePlaybackTracker.TextRegion] = [], unchanged: Bool = false) async throws -> T.Rig {
            let rig = T.Rig(); rig.plan = single([branch])
            rig.observeOverride = { _, _ in observation }
            rig.readTextOverride = { frame, platform in .init(sourceID: frame.sourceID, capturedAt: frame.capturedAt, platform: platform, regions: ocr) }
            if unchanged { rig.captureOverride = { try T.frame(after: $0) } }
            do { _ = try await rig.run() } catch is T.Failure { throw T.Failure.assertion("Unexpected test failure") } catch {}
            return rig
        }
        for branch in [PhoneTransactionPlan.Branch(id: "go", condition: "Ready", command: tap, expected: "A player", next: "$done", expectedVideo: true),
                       .init(id: "go", condition: "Ready", command: tap, expected: "Typing", next: "$done", expectedKeyboard: true),
                       .init(id: "go", condition: "Ready", command: tap, expected: "Results", next: "$done", expectedSignal: .resultsTabs)] {
            let rig = try await verify(branch)
            try T.expect(rig.actions == [.tap(0.5, 0.5)] && !rig.questions.contains { $0.id.hasSuffix(".verify") }
                && rig.records.filter { $0.pending == "go" }.count == 3 && rig.records.allSatisfy { $0.pending == nil || $0.source == .deterministic },
                "A failed deterministic postcondition was confirmed, retried, or sent to Laya")
        }
        let met = try await verify(.init(id: "go", condition: "Ready", command: tap, expected: "No results", next: "$done", expectedSignal: .noResults),
            ocr: regions([("No results for zzqx", 0.3)]))
        try T.expect(met.trace.last == "completed" && !met.questions.contains { $0.id == "task.start.verify" }
            && met.records.last?.source == .deterministic && met.records.last?.selected == "confirmed", "A met postcondition was not confirmed without Laya")
        let unchanged = try await verify(.init(id: "go", condition: "Ready", command: tap, expected: "Next screen", next: "$done"), unchanged: true)
        try T.expect(unchanged.actions == [.tap(0.5, 0.5)] && !unchanged.questions.contains { $0.id.hasSuffix(".verify") }
            && unchanged.trace.last != "completed", "A tap that left the screen unchanged was confirmed")
        let waited = try await verify(.init(id: "go", condition: "Loading", command: .init(kind: .wait, value: "", destination: "", seconds: 0.25),
            expected: "Loaded", next: "$done"), unchanged: true)
        try T.expect(waited.trace.last == "completed", "An unchanged frame after a wait was treated as pending")
    }

    static func nonVideoItems() async throws {
        let script = WarmUpScript(network: .x, activity: .watch, itemLimit: 2, duration: 300)
        let plan = PhoneTransactionPlan(version: 1, phases: script.steps.map { step in
            T.plan(command: step.id == .advance ? .init(kind: .swipe, value: "up", destination: "", seconds: 0) : nil, phase: step.id.rawValue).phases[0]
        }, watchQuery: "trading")
        let feed = T.Rig(); feed.plan = plan
        feed.observeOverride = { _, _ in screen() }
        feed.readTextOverride = { frame, platform in
            let post = feed.actions.filter { $0 == .swipe(.up) }.count
            return .init(sourceID: frame.sourceID, capturedAt: frame.capturedAt, platform: platform,
                regions: regions([("Jane Doe @janedoe · 2h", 0.16 + 0.1 * Double(post)), ("Trading post number \(post)", 0.19 + 0.1 * Double(post))]))
        }
        let result = try await feed.run(workflow: .warmUp, script: script)
        let verify = feed.records.first { $0.pending == "go" && $0.phase == "advance" }
        try T.expect(result.contains("Verified 2 item(s)") && feed.actions == [.swipe(.up)] && verify?.question?.options.map(\.id) == ["confirmed", "pending", "failed"]
            && verify?.source == .deterministic && verify?.selected == "confirmed", "An X feed scroll was not confirmed by the next post's identity")
        let blank = T.Rig(); blank.plan = plan
        blank.observeOverride = { _, _ in screen() }
        try await T.rejects { _ = try await blank.run(workflow: .warmUp, script: .init(network: .x, activity: .watch, itemLimit: 5, duration: 300)) }
        try T.expect(blank.actions == [.home, .home] && blank.questions.filter { $0.id == "advance.start" }.count == 3,
            "An unreadable item identity stopped the run instead of restarting without a swipe")
    }

    static func runnerOwnedFailures() async throws {
        func compiled(_ script: WarmUpScript, _ phases: [String: PhoneTransactionPlan.Phase]) -> PhoneTransactionPlan {
            .init(version: 1, phases: script.steps.map { phases[$0.id.rawValue] ?? T.plan(command: nil, phase: $0.id.rawValue).phases[0] })
        }
        func text(_ rows: [(String, Double)]) -> (PhoneScreenFrame, String) -> PhonePlaybackTracker.Observation {
            { frame, platform in .init(sourceID: frame.sourceID, capturedAt: frame.capturedAt, platform: platform, regions: regions(rows)) }
        }
        func message(_ rig: T.Rig, _ script: WarmUpScript) async -> String {
            do { _ = try await rig.run(workflow: .warmUp, script: script); return "" } catch { return error.localizedDescription }
        }
        let instagram = WarmUpScript(network: .instagram, activity: .watch, itemLimit: 1, duration: 300)
        let missing = T.Rig(); missing.plan = compiled(instagram, [:])
        missing.observeOverride = { _, _ in screen() }
        missing.failure = .init(stepID: "search", failureModeID: "search-not-focused", uncertain: false, terminal: false, detection: "",
            recovery: "", evidence: "", probabilities: [:], margin: 1, threshold: 0.12, promptHash: "fixture")
        let noRecovery = await message(missing, instagram)
        try T.expect(!noRecovery.contains("No saved recovery") && missing.actions == [.home, .home]
            && missing.failureSteps.filter { $0.0 == .search }.count == 9 && missing.failureSteps.allSatisfy { $0.1 == .foregroundApp },
            "A non-terminal mode without a same-id branch stopped instead of retrying and restarting")

        let tap = PhoneTransactionPlan.Command(kind: .tap, value: "The play button", destination: "", seconds: 0)
        let consume = PhoneTransactionPlan.Phase(id: "consume", entry: "start", states: [.init(id: "start", maximumVisits: 6, branches: [
            .init(id: "paused", condition: "Paused", command: tap, expected: "Playing", next: "start"),
            .init(id: "navigated-away", condition: "Left the app", command: .init(kind: .tap, value: "The Instagram icon", destination: "", seconds: 0),
                  expected: "Instagram", next: "start"),
            .init(id: "watching", condition: "Playing", command: .init(kind: .wait, value: "", destination: "", seconds: 0.25), expected: "Playing", next: "start"),
            .init(id: "complete", condition: "Replayed", command: nil, expected: "", next: "$done")])])
        for (observation, owned) in [(PhoneScreenObservation(state: .foregroundApp, appCardsVisible: false, evidence: "A paused Reel",
                                          video: .init(creator: "@yoga", caption: "Morning flow", progress: 0.4, durationSeconds: 30, playing: false)), "paused"),
                                     (screen(.home), "navigated-away")] {
            let rig = T.Rig(); rig.plan = compiled(instagram, ["consume": consume])
            rig.observeOverride = { _, _ in rig.failureSteps.contains { $0.0 == .open } ? observation : screen() }
            rig.onPerform = { _ in throw CancellationError() }
            try await T.rejects { _ = try await rig.run(workflow: .warmUp, script: instagram) }
            try T.expect(rig.records.last?.phase == "consume" && rig.records.last?.source == .shortCircuit && rig.records.last?.selected == owned
                && !rig.questions.contains { $0.id == "consume.start" } && !rig.failureSteps.contains { $0.0 == .consume },
                "The runner asked Laya about \(owned) instead of reading the observation")
        }

        let typed = PhoneTransactionPlan.Phase(id: "search", entry: "start", states: [.init(id: "start", maximumVisits: 3, branches: [
            .init(id: "field", condition: "Search field", command: .init(kind: .typeText, value: "latte art", destination: "", seconds: 0),
                  expected: "The query is typed", next: "$done")])])
        for visible in [false, true] {
            let rig = T.Rig(); rig.plan = compiled(instagram, ["search": typed])
            rig.observeOverride = { _, _ in screen() }
            rig.readTextOverride = text(visible ? [("latte art", 0.06)] : [("Search", 0.06)])
            rig.classifyOverride = { question in
                if question.id == "open.start" { throw CancellationError() }
                return question.id.hasSuffix(".verify") ? "confirmed" : question.options.first?.id
            }
            try await T.rejects { _ = try await rig.run(workflow: .warmUp, script: instagram) }
            try T.expect(rig.questions.contains { $0.id == "open.start" } == visible
                && rig.actions.contains(.home) == !visible, "A typeText Laya confirmed was accepted without the query in the search field")
        }

        let x = WarmUpScript(network: .x, activity: .watch, itemLimit: 2, duration: 300)
        let swipe = T.plan(command: .init(kind: .swipe, value: "up", destination: "", seconds: 0), phase: "advance").phases[0]
        for moves in [false, true] {
            let rig = T.Rig(); rig.plan = compiled(x, ["advance": swipe])
            rig.observeOverride = { _, _ in screen() }
            rig.readTextOverride = { frame, platform in
                let post = moves ? rig.actions.filter { $0 == .swipe(.up) }.count : 0
                return .init(sourceID: frame.sourceID, capturedAt: frame.capturedAt, platform: platform,
                    regions: regions([("Jane Doe @janedoe · 2h", 0.16), ("Latte post number \(post)", 0.19)]))
            }
            let result = await message(rig, x)
            try T.expect(moves ? result.isEmpty && rig.actions == [.swipe(.up)] : rig.actions.first == .swipe(.up) && rig.actions.contains(.home),
                "A compiled scroll that showed the same post was confirmed as the next item")
        }

        let loop = PhoneTransactionPlan.Phase(id: "open", entry: "start", states: [.init(id: "start", maximumVisits: 10, branches: [
            .init(id: "next", condition: "Another result", command: nil, expected: "", next: "start"),
            .init(id: "qualified", condition: "A qualifying video", command: nil, expected: "", next: "$done")])])
        let exhausted = T.Rig(); exhausted.plan = compiled(instagram, ["open": loop])
        exhausted.observeOverride = { _, _ in screen() }
        exhausted.budgetOverride = { _, step in .init(maxPlannerDecisions: step == .open ? 3 : 30, maxSeconds: 30) }
        exhausted.classifyOverride = { $0.id == "open.start" ? "next" : "go" }
        let noResult = await message(exhausted, instagram)
        try T.expect(noResult.contains("No qualifying result") && exhausted.actions.isEmpty,
            "An exhausted open budget did not stop as no-qualifying-result")
    }

    static func accountRecoveries() async throws {
        let script = WarmUpScript(network: .tikTok, activity: .watch, itemLimit: 1, duration: 300)
        let account = try PhoneTransactionCompiler.accountPhase(script: script)
        let plan = PhoneTransactionPlan(version: 1, phases: [account] + script.steps.dropFirst().map { T.plan(command: nil, phase: $0.id.rawValue).phases[0] })
        func launched(_ rig: T.Rig, feed: [PhonePlaybackTracker.TextRegion]) {
            rig.plan = plan
            rig.observeOverride = { _, _ in
                .init(state: rig.actions.isEmpty ? .home : .foregroundApp, appCardsVisible: false,
                    evidence: rig.actions.isEmpty ? "Home Screen with TikTok in the Dock." : "TikTok is open.")
            }
            rig.readTextOverride = { frame, platform in
                .init(sourceID: frame.sourceID, capturedAt: frame.capturedAt, platform: platform,
                    regions: rig.actions.isEmpty ? [] : rig.actions.count == 1 ? feed : profileText)
            }
            rig.classifyOverride = { question in
                guard question.id == "account.launcher.verify" else { throw CancellationError() }
                return "confirmed"
            }
        }
        let header = regions([("9:41", 0.02), ("LIVE", 0.065), ("Following", 0.065), ("For You", 0.065), ("25.4K", 0.5), ("@creator0", 0.8),
                              ("Morning market recap for swing traders", 0.83)])
        let unread = header + ["Home", "Friends", "Inbox", "Profile"].map {
            .init(text: $0, confidence: 0.3, bounds: CGRect(x: 0.2, y: 0.944, width: 0.1, height: 0.012))
        }
        let sheet = feedText + regions([("Turn on notifications", 0.55), ("Not now", 0.76)])
        for (feed, taken) in [(header, "tabs"), (unread, "tabs"), (sheet, "prompt")] {
            let rig = T.Rig(); launched(rig, feed: feed)
            try await T.rejects { _ = try await rig.run(workflow: .warmUp, script: script) }
            try T.expect(rig.records.first { $0.state == "profile" && $0.pending == nil }.map { $0.selected == taken && $0.source == .shortCircuit } == true
                && !rig.records.contains { $0.selected == "back" }, "The TikTok feed took \(rig.records.first { $0.state == "profile" }?.selected ?? "-") instead of \(taken)")
        }

        let wrong = T.Rig(); launched(wrong, feed: feedText); wrong.accountOutcome = .mismatch
        var stopped = ""
        do { _ = try await wrong.run(workflow: .warmUp, script: script) } catch { stopped = error.localizedDescription }
        try T.expect(stopped.contains("mismatch") && wrong.accountCalls == 2 && wrong.actions == [.tap(0.5, 0.5), .tap(0.5, 0.5)],
            "A handle mismatch stopped on one frame, or was not confirmed on a second frame without input")

        let blank = T.Rig(); blank.plan = try PhoneTransactionCompiler.builtIn(goal: "open TikTok", script: nil)!
        blank.observeOverride = { _, _ in .init(state: .unknown, appCardsVisible: false, evidence: "A dark transition frame.") }
        blank.classifyOverride = { _ in throw T.Failure.assertion("A frame without any offered branch asked Laya") }
        try await T.rejects { _ = try await blank.run() }
        try T.expect(blank.captures == 3 && blank.actions.isEmpty && blank.records.count == 3 && blank.records.allSatisfy { $0.selected == nil },
            "A frame no branch accepts ended the open-app workflow instead of being observed again")

        let instagram = WarmUpScript(network: .instagram, activity: .watch, itemLimit: 1, duration: 300)
        let consume = PhoneTransactionPlan.Phase(id: "consume", entry: "start", states: [.init(id: "start", maximumVisits: 6, branches: [
            .init(id: "paused", condition: "Paused", command: .init(kind: .tap, value: "The play button", destination: "", seconds: 0), expected: "Playing", next: "start"),
            .init(id: "complete", condition: "Replayed", command: nil, expected: "", next: "$done")])])
        let toggling = T.Rig()
        toggling.plan = .init(version: 1, phases: instagram.steps.map { $0.id == .consume ? consume : T.plan(command: nil, phase: $0.id.rawValue).phases[0] })
        toggling.observeOverride = { _, _ in
            toggling.failureSteps.contains { $0.0 == .open } ? .init(state: .foregroundApp, appCardsVisible: false, evidence: "A paused Reel",
                video: .init(creator: "@yoga", caption: "Morning flow", progress: 0.4, durationSeconds: 30, playing: false)) : screen()
        }
        try await T.rejects { _ = try await toggling.run(workflow: .warmUp, script: instagram) }
        try T.expect(toggling.actions == [.tap(0.5, 0.5)], "A runner-owned recovery ignored its contract attempt limit and toggled playback again")
    }

    /// Live 2026-09-27: "swipe up to show next video" compiled to negated conditions Laya scored below "unknown" three times.
    static func agentGesture() async throws {
        try T.expect(PhoneTransactionCompiler.gesture("swipe up to show next video").map { $0.direction == .up && $0.video } == true
            && PhoneTransactionCompiler.gesture("Swipe left").map { $0.direction == .left && !$0.video } == true
            && PhoneTransactionCompiler.gesture("scroll down").map { $0.direction == .up } == true
            && PhoneTransactionCompiler.gesture("swipe up and like it") == nil && PhoneTransactionCompiler.gesture("swipe up then tap follow") == nil,
            "Gesture requests were parsed wrongly, or a multi-action request became a lone swipe")
        let rig = T.Rig(); rig.plan = try PhoneTransactionCompiler.builtIn(goal: "swipe up to show next video", script: nil)!
        rig.observeOverride = { _, _ in
            .init(state: .foregroundApp, appCardsVisible: false, evidence: "TikTok video player shows a trading chart.",
                video: .init(creator: "Pat Trading", caption: "Swing trading step by step", progress: 0.2, durationSeconds: nil, playing: true))
        }
        rig.classifyOverride = { question in throw T.Failure.assertion("A lone swipe asked Laya \(question.id)") }
        let result = try await rig.run()
        try T.expect(result.contains("completed") && rig.actions == [.swipe(.up)] && rig.questions.isEmpty,
            "The swipe request was not one deterministic swipe confirmed by the playing video: \(rig.actions)")
        typealias Branch = PhoneTransactionPlan.Branch
        let compiled = PhoneTransactionPlan(version: 1, phases: [.init(id: "advance", entry: "inspect", states: [
            .init(id: "inspect", maximumVisits: 3, branches: [
                Branch(id: "videoVisible", condition: "A single video is visible in a vertical video feed, with identifiable creator or caption and no overlay or loading indicator.",
                    command: .init(kind: .swipe, value: "up", destination: "", seconds: 0), expected: "A different video is visible.", next: "$done"),
                Branch(id: "loading", condition: "A loading indicator is visible over a vertical video feed.", command: nil, expected: "", next: "inspect"),
                Branch(id: "unsupported", condition: "Neither an unobstructed identifiable video nor a loading vertical video feed is visible.",
                    command: nil, expected: "", next: "$stop")])])])
        try T.expect(PhoneTransactionCompiler.negatedConditions(compiled).count == 2
            && PhoneTransactionCompiler.negatedConditions(rig.plan).isEmpty,
            "The live compiled plan's negated conditions were not caught for a rewrite")
    }

    /// The live TikTok "Viewer history turned on" sheet: only an icon close control, over the profile the Profile tap opened.
    static func interruptDismissal() async throws {
        let script = WarmUpScript(network: .tikTok, activity: .watch, itemLimit: 1, duration: 300)
        let account = try PhoneTransactionCompiler.accountPhase(script: script)
        let plan = PhoneTransactionPlan(version: 1, phases: [account] + script.steps.dropFirst().map { T.plan(command: nil, phase: $0.id.rawValue).phases[0] })
        let sheet = regions([("9:41", 0.02), ("@fixture", 0.18), ("Following", 0.24), ("Followers", 0.24), ("Likes", 0.24),
                             ("Viewer history turned on", 0.68), ("Others will see you viewed their profile,", 0.73), ("Inbox", 0.944)])
        for closable in [true, false] {
            let rig = T.Rig(); rig.plan = plan
            rig.locate = { goal, _, _ in
                goal.contains(PhoneTransactionCompiler.interruptTarget) && !closable
                    ? .needsInput("No safe close control is visible.") : .action(.tap(0.9, Double(rig.locatorCalls) / 10), reason: "Located")
            }
            let taps = { rig.actions.filter { $0 != .home }.count }
            rig.observeOverride = { _, _ in
                switch taps() {
                case 0: .init(state: .home, appCardsVisible: false, evidence: "Home Screen with TikTok in the Dock.")
                case 2: .init(state: .dialog, appCardsVisible: false, evidence: "A Viewer history sheet with a close X covers the profile.")
                default: .init(state: .foregroundApp, appCardsVisible: false, evidence: "TikTok is open.")
                }
            }
            rig.readTextOverride = { frame, platform in
                .init(sourceID: frame.sourceID, capturedAt: frame.capturedAt, platform: platform,
                    regions: [[], feedText, sheet, profileText][min(taps(), 3)])
            }
            rig.classifyOverride = { question in
                guard question.id == "account.launcher.verify" else { throw CancellationError() }
                return "confirmed"
            }
            try await T.rejects { _ = try await rig.run(workflow: .warmUp, script: script) }
            let dismissed = rig.records.filter { $0.selected == "dismiss" }
            if closable {
                try T.expect(dismissed.count == 1 && rig.actions.count == 3 && !rig.actions.contains(.home)
                    && rig.records.contains { $0.state == "profile" && $0.pending == "tabs" && $0.selected == "confirmed" }
                    && rig.accountCalls > 0,
                    "An icon-only sheet over the profile was not closed once before verifying the account: \(rig.actions)")
            } else {
                try T.expect(dismissed.isEmpty && rig.actions.contains(.home) && rig.actions.filter { $0 != .home }.count == 2,
                    "A sheet without a safe close control was tapped instead of restarting from Home: \(rig.actions)")
            }
        }
    }

    static func captureJournal() async throws {
        let rig = T.Rig(); rig.probabilities = ["go": 0.9, "unknown": 0.1]
        rig.readTextOverride = { frame, platform in
            .init(sourceID: frame.sourceID, capturedAt: frame.capturedAt, platform: platform, regions: regions([("No results for zzqx", 0.3)]))
        }
        _ = try await rig.run()
        try T.expect(rig.records.map(\.sequence) == [1, 2] && rig.records.map(\.question?.id) == ["task.start", "task.start.verify"]
            && rig.records.allSatisfy { $0.source == .laya && $0.probabilities?["go"] == 0.9 && $0.margin == 0.5 && $0.signals.contains(.noResults) }
            && rig.records[1].pending == "go" && rig.records[1].selected == "confirmed" && rig.records[0].regions.first?.text == "No results for zzqx"
            && rig.records.allSatisfy { $0.run.hasSuffix("-prompt") && $0.run == rig.records[0].run },
            "Semantic If decisions were not captured with their question, scores, OCR, and signals")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("shortreel-capture-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let defaults = UserDefaults(suiteName: "shortreel-capture-" + UUID().uuidString)!
        try T.expect(SemanticIfCaptureJournal.configured(defaults) == nil, "Capture was on by default")
        defaults.set(directory.path, forKey: SemanticIfCaptureJournal.directoryKey)
        let journal = try SemanticIfCaptureJournal.configured(defaults) ?? { throw T.Failure.assertion("Capture directory was ignored") }()
        let frame = try T.frame(after: Date())
        for record in rig.records { journal.write(record, jpeg: frame.jpegData) }
        let folder = directory.appendingPathComponent(rig.records[0].run)
        let saved = try JSONSerialization.jsonObject(with: Data(contentsOf: folder.appendingPathComponent("0002.json"))) as? [String: Any]
        let question = saved?["question"] as? [String: Any]
        try T.expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent("0001.jpg").path)
            && (try Data(contentsOf: folder.appendingPathComponent("0002.jpg"))) == frame.jpegData
            && question?["id"] as? String == "task.start.verify" && (question?["options"] as? [Any])?.count == 3
            && saved?["source"] as? String == "laya" && (saved?["signals"] as? [String])?.contains("noResults") == true
            && (saved?["observation"] as? [String: Any])?["state"] as? String == "home", "Capture journal files are incomplete")
        SemanticIfCaptureJournal(directory: URL(fileURLWithPath: "/dev/null/capture")).write(rig.records[0], jpeg: frame.jpegData)
    }
}
