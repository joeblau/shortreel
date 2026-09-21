import Foundation
import CoreGraphics
import ImageIO

// swiftc -swift-version 6 ShortReel/Services/DevicePrompts/{WarmUpScript,DevicePromptPlan,DevicePromptPlanner,DeviceWorkflow,PhoneVisionTypes,PhoneVisualRunner,WarmUpStateTree,PhoneSubmissionCheckpoint,PhoneSubmissionGuard,PhonePlaybackTracker,DeviceRunJournal,DevicePromptSession}.swift Tests/DevicePromptSessionTests.swift -o /tmp/shortreel-prompt-session-tests
@main @MainActor
enum DevicePromptSessionTests {
    private enum TestError: LocalizedError {
        case failure(String)
        var errorDescription: String? {
            switch self { case .failure(let message): message }
        }
    }

    /// A manually released suspension point simulates a pending model decision or
    /// screen capture without relying on the timing of a real device.
    @MainActor private final class Gate {
        private(set) var isWaiting = false
        private var continuation: CheckedContinuation<Void, Never>?

        func wait() async {
            isWaiting = true
            await withCheckedContinuation { continuation = $0 }
        }

        func release() {
            precondition(isWaiting && continuation != nil)
            continuation?.resume()
            continuation = nil
        }
    }

    static func main() async throws {
        try await successfulRunRecordsSteps()
        try await blockedReasonFailsBeforeStart()
        try await missingScreenFailsWithReason()
        try await modelNeedsInputRestoresDraft()
        try await failurePrefixAndDraftRestore()
        try await cancellationIgnoresLateDecision()
        try await visualStartFiresOnce()
        try await entriesCappedAtFifty()
        try await queueRunsInOrder()
        try await stoppedQueueRequiresResume()
        try await journalRecoveryRequiresReview()
        try await journalsAreDeviceScoped()
        try await corruptJournalFailsClosed()
        try await unwritableJournalBlocksExecution()
        try await retiredSessionCannotOverwriteReplacement()
        print("Device prompt session tests passed (15 scenarios)")
    }

    private static func successfulRunRecordsSteps() async throws {
        let finalCapture = Gate()
        var captures = 0
        var decisions = 0
        var dispatched: [PhonePromptAction] = []
        var observedFrames: [PhoneScreenFrame] = []
        let runner = PhoneVisualRunner(capture: { after in
            captures += 1
            if captures == 2 { await finalCapture.wait() }
            let frame = try visualFrame(after: after)
            observedFrames.append(frame)
            return frame
        }, decide: { goal, frame, history in
            decisions += 1
            try expect(goal == "Find the Home screen with the app icons", "The visual session changed the goal")
            if decisions == 1 {
                try expect(history.isEmpty, "A new request reused another request's actions")
                return .action(.home, reason: "Return to the Home screen.")
            }
            try expect(history.count == 1 && frame.id != observedFrames[0].id, "Completion did not use a new frame after input")
            return .finished("The Home screen is visible.")
        }, perform: { dispatched.append($0) }, blockedReason: { nil })
        let session = visualSession(runner)
        session.draft = "Find the Home screen with the app icons"
        session.submit()
        try await waitUntil { finalCapture.isWaiting }
        try expect(dispatched == [.home], "The visual action did not reach the driver")
        try expect(session.isRunning && session.entries.last?.status == .running, "The session claimed completion before observing the result")
        try expect(session.entries.last?.steps.count == 1, "The session did not record its visual step")
        try expect(session.entries.last?.steps.first?.capturedAt == observedFrames.first?.capturedAt, "The session lost the frame associated with its step")
        finalCapture.release()
        try await waitUntil { !session.isRunning }
        try expect(captures == 2 && decisions == 2 && dispatched.count == 1, "The session skipped result verification or repeated input")
        try expect(session.entries.last?.status == .completed, "A visually verified result was not marked Completed")
        try expect(session.entries.last?.message == "The Home screen is visible.", "The visually verified result was replaced")
        try expect(session.draft.isEmpty, "Successful visual execution restored the submitted draft")
    }

    private static func blockedReasonFailsBeforeStart() async throws {
        var captures = 0
        let runner = PhoneVisualRunner(capture: { after in
            captures += 1
            return try visualFrame(after: after)
        }, decide: { _, _, _ in throw TestError.failure("A blocked phone used screen understanding") },
            perform: { _ in throw TestError.failure("A blocked phone sent input") }, blockedReason: { nil })
        let session = DevicePromptSession(deviceName: "Phone", blockedReason: { "Connect this phone first." },
            visualRunner: runner)
        try expect(session.unavailableReason == "Connect this phone first.", "The unavailable reason was changed")
        session.draft = "go home"
        session.submit()
        try expect(!session.isRunning && captures == 0, "A disconnected phone entered the visual loop")
        try expect(session.entries.last?.status == .failed, "The disconnected gate did not explain the failure")
        try expect(session.entries.last?.message == "Connect this phone first.", "The gate reason was changed")
        try expect(session.draft == "go home", "The disconnected gate lost the draft")
    }

    private static func missingScreenFailsWithReason() async throws {
        // No runner at all: the default explanation is used.
        let noRunner = DevicePromptSession(deviceName: "Test Phone", blockedReason: { nil })
        try expect(!noRunner.canUseScreen, "A session without a runner claimed screen access")
        noRunner.draft = "Close all apps"
        noRunner.submit()
        try expect(!noRunner.isRunning, "A screenless request started a task")
        try expect(noRunner.entries.last?.status == .failed, "A screenless request was not reported as failed")
        try expect(noRunner.entries.last?.message == "The selected model needs a live phone screen before it can choose an action.",
            "The missing-screen explanation was changed")
        try expect(noRunner.draft == "Close all apps", "The screenless request lost its draft")

        // Runner exists but the screen is unavailable: the runner's reason wins.
        var captures = 0
        let runner = PhoneVisualRunner(capture: { _ in
            captures += 1
            throw TestError.failure("Unavailable capture ran")
        }, decide: { _, _, _ in throw TestError.failure("Unavailable model ran") },
            perform: { _ in throw TestError.failure("Unexpected input") }, blockedReason: { nil })
        let session = DevicePromptSession(deviceName: "Test Phone", blockedReason: { nil },
            visualRunner: runner, visualBlockedReason: { "USB screen is unavailable" })
        try expect(!session.canUseScreen, "An unavailable screen was reported as usable")
        session.draft = "Show the Home screen"
        session.submit()
        try expect(!session.isRunning && captures == 0, "An unavailable screen was bypassed")
        try expect(session.entries.last?.status == .failed, "A lost screen was not reported as failed")
        try expect(session.entries.last?.message == "USB screen is unavailable", "The screen failure reason was hidden")
        try expect(session.draft == "Show the Home screen", "The screenless request lost its draft")
    }

    private static func modelNeedsInputRestoresDraft() async throws {
        for nextDraft in ["", "Choose the Personal account"] {
            let model = Gate()
            var captures = 0
            let runner = PhoneVisualRunner(capture: { after in
                captures += 1
                return try visualFrame(after: after)
            }, decide: { _, _, _ in
                await model.wait()
                return .needsInput("Which account should I choose?")
            }, perform: { _ in throw TestError.failure("Clarification sent an input") }, blockedReason: { nil })
            let session = visualSession(runner)
            session.draft = "Choose my account"
            session.submit()
            try await waitUntil { model.isWaiting }
            session.draft = nextDraft
            model.release()
            try await waitUntil { !session.isRunning }
            try expect(captures == 1, "Clarification captured extra frames")
            try expect(session.entries.last?.status == .needsInput, "Visual clarification did not ask for input")
            try expect(session.entries.last?.message == "Which account should I choose?", "Visual clarification text was lost")
            try expect(session.entries.last?.steps.isEmpty == true, "Clarification invented visual steps")
            try expect(session.draft == (nextDraft.isEmpty ? "Choose my account" : nextDraft), "Clarification lost the original goal or overwrote the next draft")
        }
    }

    private static func failurePrefixAndDraftRestore() async throws {
        // A failure after completed steps discloses them and keeps the draft clear.
        var dispatched: [PhonePromptAction] = []
        let runner = PhoneVisualRunner(capture: { try visualFrame(after: $0) }, decide: { _, _, history in
            if history.isEmpty { return .action(.home, reason: "Return to the Home screen.") }
            throw TestError.failure("Bluetooth write failed")
        }, perform: { dispatched.append($0) }, blockedReason: { nil })
        let session = visualSession(runner)
        session.draft = "Go home then open Mail"
        session.submit()
        try await waitUntil { !session.isRunning }
        try expect(dispatched == [.home], "Execution continued after a failed decision")
        try expect(session.entries.last?.status == .failed, "Failed run was not reported")
        try expect(session.entries.last?.message == "Stopped after 1 step. Bluetooth write failed",
            "Failure did not disclose completed input or hid the underlying error")
        try expect(session.entries.last?.steps.count == 1, "The session lost steps completed before the failure")
        try expect(session.draft.isEmpty, "A partially completed run restored its draft")

        // A failure before anything ran restores the draft for editing.
        let failingCapture = PhoneVisualRunner(capture: { _ in
            throw TestError.failure("The USB screen disconnected")
        }, decide: { _, _, _ in throw TestError.failure("Unexpected decision") },
            perform: { _ in throw TestError.failure("Unexpected input") }, blockedReason: { nil })
        let screenless = visualSession(failingCapture)
        screenless.draft = "Open Safari"
        screenless.submit()
        try await waitUntil { !screenless.isRunning }
        try expect(screenless.entries.last?.status == .failed, "A capture failure was not reported")
        try expect(screenless.entries.last?.message == "The USB screen disconnected",
            "A failure with no completed input used the stopped-after prefix")
        try expect(screenless.entries.last?.steps.isEmpty == true, "A failed capture invented visual steps")
        try expect(screenless.draft == "Open Safari", "A run that never sent input lost the draft")
    }

    private static func cancellationIgnoresLateDecision() async throws {
        let model = Gate()
        var dispatched: [PhonePromptAction] = []
        let runner = PhoneVisualRunner(capture: { try visualFrame(after: $0) }, decide: { _, _, _ in
            await model.wait() // A provider may finish despite task cancellation.
            return .action(.home, reason: "Return to the Home screen.")
        }, perform: { dispatched.append($0) }, blockedReason: { nil })
        let session = visualSession(runner)
        session.draft = "Show the Home screen with app icons"
        session.submit()
        try await waitUntil { model.isWaiting }
        session.cancel()
        try await waitUntil { !session.isRunning }
        try expect(session.entries.last?.status == .cancelled, "Stopping a visual request did not show Stopped")
        try expect(session.entries.last?.message == "Stopped. Input already sent to the phone cannot be undone.",
            "The cancellation reason was lost")
        model.release()
        await Task.yield()
        try expect(dispatched.isEmpty && session.entries.last?.steps.isEmpty == true, "A late model result sent or logged an action after Stop")
        try expect(session.entries.last?.status == .cancelled, "A late result changed the Stopped status")
    }

    private static func visualStartFiresOnce() async throws {
        var starts = 0
        var capturesAtStart: [Int] = []
        var captures = 0
        let runner = PhoneVisualRunner(capture: { after in
            captures += 1
            return try visualFrame(after: after)
        }, decide: { _, _, _ in .finished("The Home screen is visible.") },
            perform: { _ in throw TestError.failure("Already-visible goal received unnecessary input") }, blockedReason: { nil })
        let session = DevicePromptSession(deviceName: "Test Phone", blockedReason: { nil },
            visualRunner: runner, onVisualStart: {
                starts += 1
                capturesAtStart.append(captures)
            })
        session.draft = "Show the Home screen"
        session.submit()
        try await waitUntil { !session.isRunning }
        try expect(session.entries.last?.status == .completed, "The run did not complete")
        try expect(starts == 1, "onVisualStart did not fire exactly once")
        try expect(capturesAtStart == [0], "onVisualStart fired after the first capture instead of at run start")
    }

    private static func entriesCappedAtFifty() async throws {
        let session = DevicePromptSession(deviceName: "Phone", blockedReason: { "Connect this phone first." })
        for index in 1...55 {
            session.draft = "Request \(index)"
            session.submit()
        }
        try expect(session.entries.count == 50, "History grew past its cap")
        try expect(session.entries.first?.prompt == "Request 6" && session.entries.last?.prompt == "Request 55",
            "The oldest entries were not dropped first")
        try expect(session.entries.allSatisfy { $0.status == .failed }, "Capped history changed entry outcomes")
    }

    private static func queueRunsInOrder() async throws {
        let gate = Gate()
        var goals: [String] = []
        let runner = PhoneVisualRunner(capture: { try visualFrame(after: $0) }, decide: { goal, _, _ in
            goals.append(goal)
            if goals.count == 1 { await gate.wait() }
            return .finished("Verified")
        }, perform: { _ in }, blockedReason: { nil })
        let session = visualSession(runner)
        session.draft = "first"; session.submit()
        try await waitUntil { gate.isWaiting }
        session.draft = "second"; session.submit()
        session.draft = "third"; session.submit()
        try expect(session.queuedCount == 2 && goals == ["first"], "Busy requests were dropped or ran concurrently")
        session.cancelQueued(id: session.entries.last!.id)
        try expect(!session.queuePaused, "Removing one queued job paused unrelated work")
        gate.release()
        try await waitUntil { !session.isRunning }
        try expect(goals == ["first", "second"], "Device FIFO order was not preserved")
        try expect(session.entries.map(\.status) == [.completed, .completed, .cancelled], "Queue outcomes were lost")
    }

    private static func stoppedQueueRequiresResume() async throws {
        let gate = Gate()
        var goals: [String] = []
        let runner = PhoneVisualRunner(capture: { try visualFrame(after: $0) }, decide: { goal, _, _ in
            goals.append(goal)
            if goals.count == 1 { await gate.wait() }
            return .finished("Verified")
        }, perform: { _ in }, blockedReason: { nil })
        let session = visualSession(runner)
        session.draft = "first"; session.submit()
        try await waitUntil { gate.isWaiting }
        session.draft = "second"; session.submit()
        session.cancel(); gate.release()
        try await waitUntil { !session.isRunning }
        try expect(session.queuePaused && session.queuedCount == 1 && goals == ["first"], "Stop drained the remaining queue")
        session.resumeQueue()
        try await waitUntil { !session.isRunning }
        try expect(goals == ["first", "second"], "Explicit resume did not run pending work")
    }

    private static func retiredSessionCannotOverwriteReplacement() async throws {
        let journal = temporaryJournal()
        defer { try? FileManager.default.removeItem(at: journal.fileURL.deletingLastPathComponent()) }
        let gate = Gate()
        let oldRunner = PhoneVisualRunner(capture: { try visualFrame(after: $0) }, decide: { _, _, _ in
            await gate.wait(); return .finished("Late result")
        }, perform: { _ in }, blockedReason: { nil })
        let old = DevicePromptSession(deviceName: "Phone", journal: journal, blockedReason: { nil }, visualRunner: oldRunner)
        old.draft = "Old run"; old.submit()
        try await waitUntil { gate.isWaiting }
        old.retire(because: "Input connection changed")
        let newRunner = PhoneVisualRunner(capture: { try visualFrame(after: $0) },
            decide: { _, _, _ in .finished("New result") }, perform: { _ in }, blockedReason: { nil })
        let replacement = DevicePromptSession(deviceName: "Phone", journal: journal, blockedReason: { nil }, visualRunner: newRunner)
        replacement.draft = "New run"; replacement.submit()
        try await waitUntil { !replacement.isRunning }
        gate.release()
        try await waitUntil { !old.isRunning }
        let saved = try journal.load()
        try expect(saved.count == 2 && saved.last?.prompt == "New run" && saved.last?.status == .completed,
            "A discarded session overwrote newer durable history")
    }

    private static func temporaryJournal(_ device: String = "phone") -> DeviceRunJournal {
        DeviceRunJournal(deviceIdentifier: device,
            directory: FileManager.default.temporaryDirectory.appendingPathComponent("shortreel-journal-" + UUID().uuidString))
    }

    private static func journalRecoveryRequiresReview() async throws {
        let journal = temporaryJournal()
        defer { try? FileManager.default.removeItem(at: journal.fileURL.deletingLastPathComponent()) }
        let script = WarmUpScript(network: .tikTok, activity: .comment, itemLimit: 1, duration: 300)
        let uncertain = DevicePromptEntry(id: UUID(), prompt: "comment", status: .running, message: "Sending",
            steps: [.init(id: UUID(), number: 1, action: "Tap", detail: "Send", capturedAt: Date())],
            workflow: .warmUp, scriptTitle: script.title,
            submission: .init(state: .submitting, activity: "comment", updatedAt: Date(), detail: "Before sending"),
            scriptCheckpoint: WarmUpScriptCursor(script: script).checkpoint, warmUpScript: script)
        let queued = DevicePromptEntry(id: UUID(), prompt: "next", status: .queued, message: "Queued")
        try journal.save([uncertain, queued])
        var goals: [String] = []
        let runner = PhoneVisualRunner(capture: { try visualFrame(after: $0) }, decide: { goal, _, _ in
            goals.append(goal); return .finished("Verified")
        }, perform: { _ in }, blockedReason: { nil })
        let recovered = DevicePromptSession(deviceName: "Renamed Phone", journal: journal,
            blockedReason: { nil }, visualRunner: runner)
        try expect(recovered.entries.first?.status == .needsReview && !recovered.isRunning && recovered.queuePaused,
            "Interrupted execution resumed without review")
        try expect(recovered.entries.first?.warmUpScript == script && recovered.entries.first?.scriptCheckpoint != nil,
            "Versioned script or checkpoint was lost")
        try expect(recovered.entries.first?.steps.count == 1 && recovered.entries.first?.submission?.state == .submitting,
            "Execution evidence was lost")
        recovered.resumeQueue()
        try expect(goals.isEmpty && !recovered.isRunning, "Pending jobs ran before uncertain submission review")
        recovered.acknowledgeReview(id: uncertain.id)
        recovered.resumeQueue()
        try await waitUntil { !recovered.isRunning }
        try expect(goals == ["next"], "Recovery retried the uncertain submission or lost queued work")
        let saved = try journal.load()
        try expect(saved.first?.reviewedAt != nil && saved.last?.status == .completed, "Recovery acknowledgement was not durable")
        let json = try String(contentsOf: journal.fileURL, encoding: .utf8)
        try expect(!json.contains("jpegData") && !json.contains("beforeFrame"), "Journal retained screenshot payloads")
    }

    private static func journalsAreDeviceScoped() async throws {
        let first = temporaryJournal("first")
        defer { try? FileManager.default.removeItem(at: first.fileURL.deletingLastPathComponent()) }
        let second = DeviceRunJournal(deviceIdentifier: "second", directory: first.fileURL.deletingLastPathComponent())
        try first.save([.init(id: UUID(), prompt: "Only first", status: .completed, message: "Done")])
        let secondEntries = try second.load()
        try expect(secondEntries.isEmpty, "Another device inherited a run")
        try expect(first.fileURL != second.fileURL, "Device histories share a file")
    }

    private static func corruptJournalFailsClosed() async throws {
        let journal = temporaryJournal()
        defer { try? FileManager.default.removeItem(at: journal.fileURL.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: journal.fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let original = Data("not a journal".utf8)
        try original.write(to: journal.fileURL)
        let session = DevicePromptSession(deviceName: "Phone", journal: journal, blockedReason: { nil })
        session.draft = "Do something"; session.submit(); session.resumeQueue()
        try expect(session.persistenceError != nil && !session.isRunning, "Corrupt history allowed execution")
        let preserved = try Data(contentsOf: journal.fileURL)
        try expect(preserved == original, "Unreadable journal was overwritten")
    }

    private static func unwritableJournalBlocksExecution() async throws {
        let journal = DeviceRunJournal(deviceIdentifier: "phone", directory: URL(fileURLWithPath: "/dev/null/shortreel"))
        var captures = 0
        let runner = PhoneVisualRunner(capture: { after in captures += 1; return try visualFrame(after: after) },
            decide: { _, _, _ in .finished("Unexpected") }, perform: { _ in }, blockedReason: { nil })
        let session = DevicePromptSession(deviceName: "Phone", journal: journal, blockedReason: { nil }, visualRunner: runner)
        session.draft = "Run"; session.submit()
        try expect(captures == 0 && !session.isRunning && session.persistenceError != nil, "Failed durable storage allowed dispatch")
    }

    private static func visualSession(_ runner: PhoneVisualRunner) -> DevicePromptSession {
        DevicePromptSession(deviceName: "Test Phone", blockedReason: { nil }, visualRunner: runner)
    }

    private static func visualFrame(after: Date) throws -> PhoneScreenFrame {
        guard let context = CGContext(data: nil, width: 8, height: 12, bitsPerComponent: 8,
            bytesPerRow: 32, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
            throw TestError.failure("Could not create test screen")
        }
        context.setFillColor(red: 0.3, green: 0.5, blue: 0.7, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 8, height: 12))
        guard let image = context.makeImage() else { throw TestError.failure("Could not make test screen") }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil) else {
            throw TestError.failure("Could not create test JPEG")
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw TestError.failure("Could not encode test JPEG") }
        return .init(id: UUID(), capturedAt: max(Date(), after.addingTimeInterval(0.000_001)),
            pixelWidth: 8, pixelHeight: 12, jpegData: data as Data, cgImage: image, sourceID: "Test Phone")
    }

    private static func waitUntil(_ predicate: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(2)
        while !predicate() {
            guard ContinuousClock.now < deadline else { throw TestError.failure("Timed out waiting for session state") }
            try await Task.sleep(for: .milliseconds(1))
        }
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw TestError.failure(message) }
    }
}
