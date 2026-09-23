import Foundation

@main @MainActor enum DevicePromptSessionTests {
    typealias T = TransactionTestSupport
    static func main() async throws {
        try await bothEntryPointsSaveTransactions()
        try await gatesAndDrafts()
        try await serialQueueAndCancellation()
        try await pendingInputRequiresReview()
        try await journalRoundTripAndLegacyRecovery()
        try await journalFailureAndIsolation()
        try await retiredSessionCannotOverwriteReplacement()
        try await historyCap()
        try await restartPurgesHistory()
        try await freshWatchAfterRestart()
        print("Device session tests passed (Agent/Stage persistence, gates, queue, cancellation, recovery, journal failures, retirement, history)")
    }
    static func session(_ rig: T.Rig, journal: DeviceRunJournal? = nil) -> DevicePromptSession {
        DevicePromptSession(deviceName: "Phone", journal: journal, blockedReason: { nil }, visualRunner: rig.runner())
    }
    static func bothEntryPointsSaveTransactions() async throws {
        for workflow: DeviceWorkflow? in [nil, .createContent] {
            let journal = T.journal(); defer { try? FileManager.default.removeItem(at: journal.fileURL.deletingLastPathComponent()) }
            let rig = T.Rig(); let gate = T.Gate()
            rig.captureOverride = { after in
                if rig.captures == 2 { await gate.wait() }
                return try T.frame(after: after)
            }
            let session = session(rig, journal: journal)
            if let workflow { session.submit(workflow: workflow, details: "Save a draft") }
            else { session.draft = "Go Home"; session.submit() }
            try await T.until { gate.waiting }
            let pending = try journal.load().last!
            try T.expect(pending.transactionPlan == rig.plan && pending.transactionCheckpoint?.status == .verifying && pending.transactionCheckpoint?.input != nil,
                "Plan or pre-input checkpoint was not durable")
            try T.expect(session.isRunning && session.entries.last?.status == .running, "Completed before observing input result")
            gate.release(); try await T.until { !session.isRunning }
            let saved = try journal.load().last!
            try T.expect(saved.status == .completed && saved.transactionCheckpoint?.status == .completed && saved.steps.count == 2, "Verified result was not saved")
            try T.expect(session.draft.isEmpty && rig.actions == [.home], "Completed request retained draft or repeated input")
            let json = try String(contentsOf: journal.fileURL, encoding: .utf8)
            try T.expect(!json.contains("jpegData") && !json.contains("beforeFrame"), "Journal retained screenshots")
        }
    }
    static func gatesAndDrafts() async throws {
        let rig = T.Rig()
        let blocked = DevicePromptSession(deviceName: "Phone", blockedReason: { "Disconnected" }, visualRunner: rig.runner())
        blocked.draft = "go home"; blocked.submit()
        try T.expect(blocked.entries.last?.status == .failed && blocked.draft == "go home" && rig.captures == 0, "Connection gate regressed")
        let screenless = DevicePromptSession(deviceName: "Phone", blockedReason: { nil })
        screenless.draft = "go home"; screenless.submit()
        try T.expect(!screenless.isRunning && screenless.entries.last?.status == .failed && screenless.draft == "go home", "Screen gate regressed")
        for nextDraft in ["", "next request"] {
            let rig = T.Rig(); let gate = T.Gate()
            rig.compileOverride = { _, _ in await gate.wait(); throw PhonePromptPlanningError.needsClarification("Specify the account") }
            let session = session(rig)
            session.draft = "Open profile"; session.submit()
            try await T.until { gate.waiting }; session.draft = nextDraft; gate.release()
            try await T.until { !session.isRunning }
            try T.expect(session.entries.last?.status == .needsInput && session.entries.last?.message == "Specify the account", "Compiler clarification was lost")
            try T.expect(session.draft == (nextDraft.isEmpty ? "Open profile" : nextDraft) && rig.actions.isEmpty, "Clarification overwrote draft or ran input")
        }
        var starts = 0
        let success = T.Rig()
        let started = DevicePromptSession(deviceName: "Phone", blockedReason: { nil }, visualRunner: success.runner(), onVisualStart: { starts += 1 })
        started.draft = "home"; started.submit(); try await T.until { !started.isRunning }
        try T.expect(starts == 1, "Start callback was not once per run")
    }
    static func serialQueueAndCancellation() async throws {
        let rig = T.Rig(); let gate = T.Gate()
        rig.compileOverride = { _, _ in
            if rig.compileGoals.count == 1 { await gate.wait() }
            return rig.plan
        }
        let session = session(rig)
        session.draft = "first"; session.submit(); try await T.until { gate.waiting }
        session.draft = "second"; session.submit()
        try T.expect(session.queuedCount == 1 && rig.compileGoals == ["first"], "Queue ran concurrently")
        session.cancel(); gate.release(); try await T.until { !session.isRunning }
        try T.expect(session.queuePaused && session.queuedCount == 1 && rig.actions.isEmpty, "Cancellation drained queue or late compilation dispatched")
        session.resumeQueue(); try await T.until { !session.isRunning }
        try T.expect(rig.compileGoals == ["first", "second"] && session.entries.map(\.status) == [.cancelled, .completed], "Explicit resume did not preserve order")
    }
    static func pendingInputRequiresReview() async throws {
        let rig = T.Rig()
        rig.classifyOverride = { question in
            if question.id.hasSuffix(".verify") { throw CocoaError(.fileReadUnknown) }
            return "go"
        }
        let session = session(rig)
        session.draft = "Go home"; session.submit(); try await T.until { !session.isRunning }
        try T.expect(session.entries.last?.status == .needsReview && session.hasUnreviewedRuns && rig.actions == [.home], "Unverified physical input was retryable")
        session.draft = "next"; session.submit()
        try T.expect(session.queuedCount == 1 && !session.isRunning, "Pending input did not block queue")
    }
    static func journalRoundTripAndLegacyRecovery() async throws {
        for legacy in [true, false] {
            let journal = T.journal(); defer { try? FileManager.default.removeItem(at: journal.fileURL.deletingLastPathComponent()) }
            let id = UUID()
            let interrupted = DevicePromptEntry(id: id, prompt: "interrupted", status: .running, message: "Running",
                transactionPlan: legacy ? nil : T.plan(), transactionCheckpoint: legacy ? nil : .init(phase: "task", state: "start", branch: "go", status: .dispatching, input: "home", visits: ["task.start": 1]))
            let queued = DevicePromptEntry(id: UUID(), prompt: "next", status: .queued, message: "Queued")
            try journal.save([interrupted, queued])
            if legacy {
                var json = try JSONSerialization.jsonObject(with: Data(contentsOf: journal.fileURL)) as! [String: Any]
                var entries = json["entries"] as! [[String: Any]]
                for index in entries.indices { entries[index].removeValue(forKey: "transactionPlan"); entries[index].removeValue(forKey: "transactionCheckpoint") }
                json["entries"] = entries
                try JSONSerialization.data(withJSONObject: json).write(to: journal.fileURL)
            }
            let rig = T.Rig(); let restored = session(rig, journal: journal)
            try T.expect(restored.entries.first?.status == .needsReview && restored.queuePaused && rig.actions.isEmpty, "Restart replayed a transaction")
            restored.resumeQueue()
            try T.expect(!restored.isRunning, "Queue resumed without review")
            restored.acknowledgeReview(id: id); restored.resumeQueue(); try await T.until { !restored.isRunning }
            try T.expect(rig.compileGoals == ["next"] && restored.entries.last?.status == .completed, "Review replayed old run or lost queued work")
            try T.expect(try journal.load().first?.reviewedAt != nil, "Review acknowledgement was not durable")
        }
    }
    static func journalFailureAndIsolation() async throws {
        let journal = T.journal(); defer { try? FileManager.default.removeItem(at: journal.fileURL.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: journal.fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not JSON".utf8).write(to: journal.fileURL)
        let rig = T.Rig(); let broken = session(rig, journal: journal)
        broken.draft = "run"; broken.submit()
        try T.expect(broken.persistenceError != nil && !broken.isRunning && rig.actions.isEmpty, "Corrupt history allowed execution")
        try T.expect(try String(contentsOf: journal.fileURL, encoding: .utf8) == "not JSON", "Corrupt history was overwritten")
        let unwritable = DeviceRunJournal(deviceIdentifier: "phone", directory: URL(fileURLWithPath: "/dev/null/shortreel"))
        let failed = session(rig, journal: unwritable); failed.draft = "run"; failed.submit()
        try T.expect(failed.persistenceError != nil && !failed.isRunning && rig.actions.isEmpty, "Unwritable journal allowed execution")
        let first = T.journal(); defer { try? FileManager.default.removeItem(at: first.fileURL.deletingLastPathComponent()) }
        let second = DeviceRunJournal(deviceIdentifier: "second", directory: first.fileURL.deletingLastPathComponent())
        try first.save([.init(id: UUID(), prompt: "one", status: .completed, message: "done")])
        try T.expect(try second.load().isEmpty, "Device histories overlapped")
        let invalid = DevicePromptEntry(id: UUID(), prompt: "bad", status: .running, message: "bad", transactionPlan: T.plan(),
            transactionCheckpoint: .init(phase: "missing", state: "start", branch: nil, status: .dispatching, input: "home", visits: [:]))
        try first.save([invalid])
        let invalidSession = session(rig, journal: first)
        try T.expect(invalidSession.persistenceError != nil, "Invalid saved state was accepted")
    }
    static func retiredSessionCannotOverwriteReplacement() async throws {
        let journal = T.journal(); defer { try? FileManager.default.removeItem(at: journal.fileURL.deletingLastPathComponent()) }
        let gate = T.Gate(); let oldRig = T.Rig()
        oldRig.compileOverride = { _, _ in await gate.wait(); return oldRig.plan }
        let old = session(oldRig, journal: journal); old.draft = "old"; old.submit()
        try await T.until { gate.waiting }; old.retire(because: "Replaced")
        let new = session(T.Rig(), journal: journal); new.draft = "new"; new.submit()
        try await T.until { !new.isRunning }; gate.release(); try await T.until { !old.isRunning }
        let saved = try journal.load()
        try T.expect(saved.count == 2 && saved.last?.prompt == "new" && saved.last?.status == .completed, "Late retired run overwrote new history")
    }
    static func restartPurgesHistory() async throws {
        let old = T.journal()
        defer { try? FileManager.default.removeItem(at: old.fileURL.deletingLastPathComponent()) }
        let terminal = DevicePromptEntry(id: UUID(), prompt: "private old request", status: .failed, message: "old result")
        let queued = DevicePromptEntry(id: UUID(), prompt: "old queued request", status: .queued, message: "Queued")
        let preparing = DevicePromptEntry(id: UUID(), prompt: "never dispatched", status: .running, message: "Preparing workflow")
        try old.save([terminal, queued, preparing])
        let fresh = DeviceRunJournal(deviceIdentifier: "phone", directory: old.fileURL.deletingLastPathComponent(), appSessionID: UUID())
        let rig = T.Rig()
        let cleared = session(rig, journal: fresh)
        try T.expect(cleared.entries.isEmpty && cleared.queuedCount == 0 && !cleared.hasUnreviewedRuns, "Restart retained old chat or queued jobs")
        try T.expect(try !String(contentsOf: fresh.fileURL, encoding: .utf8).contains("private old request"), "Purged history remained on disk")
        let interrupted = DevicePromptEntry(id: UUID(), prompt: "interrupted input", status: .running, message: "Running",
            transactionPlan: T.plan(), transactionCheckpoint: .init(phase: "task", state: "start", branch: "go", status: .dispatching, input: "home", visits: [:]))
        try old.save([interrupted])
        let protected = session(rig, journal: fresh)
        try T.expect(protected.entries.isEmpty && protected.restartRequiresReview, "Restart lost input uncertainty or kept old transcript")
        protected.draft = "new request"; protected.submit()
        try T.expect(!protected.isRunning && rig.actions.isEmpty, "Unreviewed interrupted input allowed another run")
        protected.acknowledgeRestartReview()
        try await T.until { !protected.isRunning }
        try T.expect(protected.entries.last?.status == .completed && rig.compileGoals == ["new request"], "Review replayed the interrupted request")
        let anotherLaunch = DeviceRunJournal(deviceIdentifier: "phone", directory: old.fileURL.deletingLastPathComponent(), appSessionID: UUID())
        let next = session(T.Rig(), journal: anotherLaunch)
        try T.expect(next.entries.isEmpty && !next.restartRequiresReview, "Acknowledged review persisted across restart")
    }
    static func freshWatchAfterRestart() async throws {
        let old = T.journal()
        defer { try? FileManager.default.removeItem(at: old.fileURL.deletingLastPathComponent()) }
        let fresh = DeviceRunJournal(deviceIdentifier: "phone", directory: old.fileURL.deletingLastPathComponent(), appSessionID: UUID())
        let watch = WarmUpScript(network: .tikTok, activity: .watch, itemLimit: 3, duration: 300)
        let goal = "Platform: TikTok\nAccount check: Verify exactly @fixture, before browsing."
        try old.save([], restartRequiresReview: true)
        let rig = T.Rig()
        rig.plan = .init(version: 1, phases: [try PhoneTransactionCompiler.accountPhase(script: watch)]
            + watch.steps.dropFirst().map { T.plan(command: nil, phase: $0.id.rawValue).phases[0] })
        rig.observeOverride = { _, _ in
            .init(state: rig.actions.isEmpty ? .home : .foregroundApp, appCardsVisible: false,
                evidence: rig.actions.isEmpty ? "Home Screen with TikTok in the Dock." : "TikTok is open.")
        }
        rig.classifyOverride = { question in
            if question.id.hasSuffix(".verify") { return "confirmed" }
            switch question.id {
            case "account.start": return "home"
            case "account.launcher": return "present"
            case "account.profile": return "profile"
            default: throw CancellationError()
            }
        }
        let current = session(rig, journal: fresh)
        current.submit(workflow: .warmUp, details: goal, warmUpScript: watch)
        try T.expect(current.isRunning && current.queuedCount == 0 && current.restartRequiresReview,
            "Legacy restart gate blocked a fresh Watch or discarded submission uncertainty")
        try await T.until { !current.isRunning }
        try T.expect(rig.compileGoals == [goal], "Watch replayed the old request")
        try T.expect(rig.captures >= 5 && rig.actions == [.tap(0.5, 0.5), .tap(0.5, 0.5)]
            && rig.accountCalls == 1 && rig.questions.contains { $0.id == "search.start" },
            "Stage Watch did not enter the Semantic If screen loop after restart")
        try T.expect(!current.queuePaused, "Legacy review flag paused Watch after it started")

        let interrupted = DevicePromptEntry(id: UUID(), prompt: "old watch", status: .needsReview, message: "Interrupted",
            workflow: .warmUp, transactionCheckpoint: .init(phase: "account", state: "launcher", branch: nil,
                status: .verifying, input: "tap", visits: [:]), warmUpScript: watch)
        try old.save([interrupted])
        let cleared = session(T.Rig(), journal: fresh)
        try T.expect(cleared.entries.isEmpty && !cleared.restartRequiresReview && !cleared.queuePaused,
            "Interrupted Watch navigation still left a restart gate")

        var publishing = interrupted
        publishing.submission = .init(state: .uncertain, activity: "post", updatedAt: Date(), detail: "Unconfirmed")
        try old.save([publishing])
        let publishingRig = T.Rig(); let publishingGate = T.Gate()
        publishingRig.compileOverride = { _, _ in await publishingGate.wait(); throw CancellationError() }
        let protected = session(publishingRig, journal: fresh)
        let post = WarmUpScript(network: .tikTok, activity: .post, itemLimit: 1, duration: 300)
        protected.submit(workflow: .warmUp, details: goal, warmUpScript: post)
        try T.expect(protected.queueRequiresReview && protected.queuedCount == 1 && !protected.isRunning,
            "Uncertain publication did not block a new Post")
        try T.expect(protected.entries.last?.message.contains("reviewed") == true, "Queue hid its actual blocking reason")
        protected.acknowledgeRestartReview()
        try await T.until { publishingGate.waiting }
        try T.expect(publishingRig.compileGoals == [goal], "Acknowledgement required another Resume or replayed publication")
        protected.cancel(); publishingGate.release(); try await T.until { !protected.isRunning }
    }
    static func historyCap() async throws {
        let rig = T.Rig(); rig.plan = T.plan(command: nil)
        let session = session(rig)
        for index in 0..<53 {
            session.draft = "request \(index)"; session.submit(); try await T.until { !session.isRunning }
        }
        try T.expect(session.entries.count == 50 && session.entries.last?.prompt == "request 52", "History cap lost current entries")
    }
}
