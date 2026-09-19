import Foundation
import CoreGraphics
import ImageIO

// swiftc -swift-version 6 ShortReel/Services/DevicePrompts/DevicePromptPlan.swift ShortReel/Services/DevicePrompts/DevicePromptPlanner.swift ShortReel/Services/DevicePrompts/PhoneVisionTypes.swift ShortReel/Services/DevicePrompts/PhoneVisualRunner.swift ShortReel/Services/DevicePrompts/DevicePromptSession.swift Tests/DevicePromptSessionTests.swift -o /tmp/shortreel-prompt-session-tests
@main @MainActor
enum DevicePromptSessionTests {
    private enum TestError: LocalizedError {
        case failure(String)
        var errorDescription: String? {
            switch self { case .failure(let message): message }
        }
    }

    /// A manually released suspension point simulates a pending planner or
    /// Bluetooth write without relying on the timing of a real device.
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
        try await sequentialDispatch()
        try await planningRejection()
        try await invalidPlanPreflight()
        try await executionFailure()
        try await cancellationDuringPlanning()
        try await cancellationDuringExecution()
        try await cancellationWinsOverDelayedError()
        try await disconnectedGate()
        try await disconnectBetweenActions()
        try await duplicateSubmission()
        try await perDeviceIsolation()
        try await visualCompletionRequiresFinalFrame()
        try await visualCancellationIgnoresLateDecision()
        try await visualClarificationRestoresDraft()
        try await bluetoothOnlyWithUnavailableVisualRunner()
        try await bluetoothOnlyRejectsAmbiguousVisualGoal()
        try await cachedSessionAdoptsAvailableScreen()
        try await lostScreenNeverFallsBack()
        try await routingIsChosenAtSubmission()
        try await literalCommandsBypassAvailableVision()
        try await appNavigationUsesVisionAndVerifiesResult()
        try await invalidVisualNavigationNeverRunsBlindPlan()
        try await unknownTailNeverExecutesKnownPrefix()
        print("Device prompt session tests passed (23 scenarios)")
    }

    private static func sequentialDispatch() async throws {
        let gate = Gate()
        let expected: [PhonePromptAction] = [.home, .openApp("Safari"), .swipe(.up)]
        var dispatched: [PhonePromptAction] = []
        let session = makeSession(actions: expected) { action in
            dispatched.append(action)
            if dispatched.count == 1 { await gate.wait() }
        }
        session.draft = "Go home then open Safari then swipe up"
        session.submit()
        try await waitUntil { gate.isWaiting }
        try expect(session.isRunning && session.entries.last?.status == .running, "Running state must include a pending input")
        try expect(dispatched == [.home], "Later actions started before the first action completed")
        gate.release()
        try await waitUntil { !session.isRunning }
        try expect(dispatched == expected, "Actions were not dispatched in plan order")
        try expect(session.entries.last?.status == .sent, "Completed writes were not reported as sent")
        try expect(session.entries.last?.message.contains("Check the phone") == true, "The session claimed a verified screen result")
        try expect(session.draft.isEmpty, "A submitted successful draft was not cleared")
    }

    private static func planningRejection() async throws {
        var dispatched: [PhonePromptAction] = []
        let session = DevicePromptSession(deviceName: "Phone", blockedReason: { nil }, planner: {
            try DevicePromptPlanner.plan($0)
        }, perform: { dispatched.append($0) })
        let prompt = "go home then tap Like"
        session.draft = prompt
        session.submit()
        try await waitUntil { !session.isRunning }
        try expect(dispatched.isEmpty, "An understood prefix ran before the unknown step was rejected")
        try expect(session.entries.last?.status == .needsInput, "Unknown requests must ask for clarification")
        try expect(session.draft == prompt, "The rejected draft was lost")
    }

    private static func invalidPlanPreflight() async throws {
        // Even an injected/model planner must not bypass whole-plan validation.
        for actions: [PhonePromptAction] in [
            [.home, .typeText("😀")],
            [.home, .tap(.nan, 0.5)],
            [.home, .search("")],
            [],
        ] {
            var dispatched: [PhonePromptAction] = []
            let session = makeSession(actions: actions) { dispatched.append($0) }
            session.draft = "Run an invalid generated plan"
            session.submit()
            try await waitUntil { !session.isRunning }
            try expect(dispatched.isEmpty, "An invalid generated plan sent partial input")
            try expect(session.entries.last?.status == .needsInput, "Invalid generated plans must ask for clarification")
        }
    }

    private static func executionFailure() async throws {
        var dispatched: [PhonePromptAction] = []
        let session = makeSession(actions: [.home, .press(.enter), .swipe(.up)]) { action in
            dispatched.append(action)
            if action == .press(.enter) { throw TestError.failure("Bluetooth write failed") }
        }
        session.draft = "go home then press enter then swipe up"
        session.submit()
        try await waitUntil { !session.isRunning }
        try expect(dispatched == [.home, .press(.enter)], "Execution continued after a failed write")
        try expect(session.entries.last?.status == .failed, "Failed write was not reported")
        try expect(session.entries.last?.message.contains("Stopped after 1 action") == true, "Failure did not disclose completed input")
        try expect(session.entries.last?.message.contains("Bluetooth write failed") == true, "Failure hid the underlying error")
    }

    private static func cancellationDuringPlanning() async throws {
        let gate = Gate()
        var dispatched: [PhonePromptAction] = []
        let session = DevicePromptSession(deviceName: "Phone", blockedReason: { nil }, planner: { _ in
            await gate.wait()
            return .init(actions: [.home, .swipe(.up)])
        }, perform: { dispatched.append($0) })
        session.draft = "Return to my phone's main screen"
        session.submit()
        try await waitUntil { gate.isWaiting }
        session.cancel()
        gate.release()
        try await waitUntil { !session.isRunning }
        try expect(dispatched.isEmpty, "A cancelled planner result was executed")
        try expect(session.entries.last?.status == .cancelled, "Planning cancellation was not reported")
    }

    private static func cancellationDuringExecution() async throws {
        let gate = Gate()
        var dispatched: [PhonePromptAction] = []
        let session = makeSession(actions: [.home, .press(.enter), .swipe(.up)]) { action in
            dispatched.append(action)
            await gate.wait()
        }
        session.draft = "go home then press enter then swipe up"
        session.submit()
        try await waitUntil { gate.isWaiting }
        session.cancel(because: "Stopped because the phone disconnected.")
        try expect(session.isRunning, "The session released its task before an in-flight write finished")
        session.draft = "go home"
        session.submit()
        try expect(session.entries.count == 1, "A second task started while cancellation was pending")
        gate.release()
        try await waitUntil { !session.isRunning }
        try expect(dispatched == [.home], "Later actions were sent after cancellation")
        try expect(session.entries.last?.status == .cancelled, "Execution cancellation was not reported")
        try expect(session.entries.last?.message == "Stopped because the phone disconnected.", "The cancellation reason was lost")
        try expect(session.draft == "go home", "Cancellation overwrote the user's next draft")
    }

    private static func cancellationWinsOverDelayedError() async throws {
        for planningFailure in [true, false] {
            let gate = Gate()
            let session = DevicePromptSession(deviceName: "Phone", blockedReason: { nil }, planner: { _ in
                if planningFailure {
                    await gate.wait()
                    throw PhonePromptPlanningError.needsClarification("Delayed planning error")
                }
                return .init(actions: [.home])
            }, perform: { _ in
                await gate.wait()
                throw TestError.failure("Delayed Bluetooth failure")
            })
            session.draft = "Show my main screen"
            session.submit()
            try await waitUntil { gate.isWaiting }
            session.cancel()
            gate.release()
            try await waitUntil { !session.isRunning }
            try expect(session.entries.last?.status == .cancelled, "A delayed error replaced a user's cancellation")
        }
    }

    private static func disconnectedGate() async throws {
        var planningCalls = 0
        var dispatched: [PhonePromptAction] = []
        let session = DevicePromptSession(deviceName: "Phone", blockedReason: { "Connect this phone first." }, planner: { _ in
            planningCalls += 1
            return .init(actions: [.home])
        }, perform: { dispatched.append($0) })
        session.draft = "go home"
        session.submit()
        try expect(!session.isRunning && planningCalls == 0 && dispatched.isEmpty, "A disconnected phone entered planning/execution")
        try expect(session.entries.last?.status == .failed, "The disconnected gate did not explain the failure")
        try expect(session.entries.last?.message == "Connect this phone first.", "The gate reason was changed")
        try expect(session.draft == "go home", "The disconnected gate lost the draft")
    }

    private static func disconnectBetweenActions() async throws {
        var connected = true
        var dispatched: [PhonePromptAction] = []
        let session = DevicePromptSession(deviceName: "Phone", blockedReason: {
            connected ? nil : "The phone disconnected."
        }, planner: { _ in .init(actions: [.home, .swipe(.up)]) }, perform: {
            dispatched.append($0)
            connected = false
        })
        session.draft = "go home then swipe up"
        session.submit()
        try await waitUntil { !session.isRunning }
        try expect(dispatched == [.home], "The connection gate was not rechecked between actions")
        try expect(session.entries.last?.status == .failed, "A mid-plan disconnect was not reported")
        try expect(session.entries.last?.message.contains("Stopped after 1 action") == true, "A mid-plan disconnect hid completed input")
    }

    private static func duplicateSubmission() async throws {
        let gate = Gate()
        var planningCalls = 0
        var dispatched: [PhonePromptAction] = []
        let session = DevicePromptSession(deviceName: "Phone", blockedReason: { nil }, planner: { _ in
            planningCalls += 1
            await gate.wait()
            return .init(actions: [.home])
        }, perform: { dispatched.append($0) })
        session.draft = "Return to the phone's main page"
        session.submit()
        session.draft = "scroll down"
        session.submit()
        try await waitUntil { gate.isWaiting }
        try expect(session.entries.count == 1 && planningCalls == 1, "Concurrent submission started duplicate work")
        gate.release()
        try await waitUntil { !session.isRunning }
        try expect(dispatched == [.home], "Concurrent submission sent extra input")
        try expect(session.draft == "scroll down", "Concurrent submission lost the next draft")
    }

    private static func perDeviceIsolation() async throws {
        let gate = Gate()
        var firstActions: [PhonePromptAction] = []
        var secondActions: [PhonePromptAction] = []
        let first = makeSession(actions: [.home, .press(.enter)]) {
            firstActions.append($0)
            await gate.wait()
        }
        let second = makeSession(actions: [.openApp("Settings")]) { secondActions.append($0) }
        first.draft = "go home then press enter"
        first.submit()
        try await waitUntil { gate.isWaiting }
        second.draft = "open Settings"
        second.submit()
        try await waitUntil { !second.isRunning }
        try expect(first.isRunning && second.entries.last?.status == .sent, "A busy phone blocked another phone")
        first.cancel()
        gate.release()
        try await waitUntil { !first.isRunning }
        try expect(firstActions == [.home] && secondActions == [.openApp("Settings")], "Actions crossed device sessions")
        try expect(first.entries.last?.status == .cancelled && second.entries.last?.status == .sent, "Cancellation crossed device sessions")
        try expect(first.entries.first?.prompt != second.entries.first?.prompt, "Device histories were shared")
    }

    private static func visualCompletionRequiresFinalFrame() async throws {
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

    private static func visualCancellationIgnoresLateDecision() async throws {
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
        model.release()
        await Task.yield()
        try expect(dispatched.isEmpty && session.entries.last?.steps.isEmpty == true, "A late model result sent or logged an action after Stop")
        try expect(session.entries.last?.status == .cancelled, "A late result changed the Stopped status")
    }

    private static func visualClarificationRestoresDraft() async throws {
        for nextDraft in ["", "Choose the Personal account"] {
            let model = Gate()
            let runner = PhoneVisualRunner(capture: { try visualFrame(after: $0) }, decide: { _, _, _ in
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
            try expect(session.entries.last?.status == .needsInput, "Visual clarification did not ask for input")
            try expect(session.entries.last?.message == "Which account should I choose?", "Visual clarification text was lost")
            try expect(session.draft == (nextDraft.isEmpty ? "Choose my account" : nextDraft), "Clarification lost the original goal or overwrote the next draft")
        }
    }

    private static func bluetoothOnlyWithUnavailableVisualRunner() async throws {
        var captures = 0
        var dispatched: [PhonePromptAction] = []
        let runner = PhoneVisualRunner(capture: { after in
            captures += 1
            return try visualFrame(after: after)
        }, decide: { _, _, _ in throw TestError.failure("A Bluetooth-only request used screen understanding") },
            perform: { _ in throw TestError.failure("A Bluetooth-only request used the visual driver") },
            blockedReason: { "USB screen is unavailable" })
        let session = DevicePromptSession(deviceName: "Test Phone", blockedReason: { nil },
            planner: { try DevicePromptPlanner.plan($0) }, perform: { dispatched.append($0) },
            visualRunner: runner, visualBlockedReason: { "USB screen is unavailable" })
        try expect(session.unavailableReason == nil, "Unavailable USB blocked Bluetooth-only commands")
        let cases: [(String, [PhonePromptAction])] = [
            ("Open Safari", [.openApp("Safari")]),
            ("Search for cats", [.search("cats")]),
            ("Go home then Open Safari", [.home, .openApp("Safari")]),
        ]
        for (prompt, expected) in cases {
            dispatched.removeAll()
            session.draft = prompt
            session.submit()
            try await waitUntil { !session.isRunning }
            try expect(dispatched == expected && captures == 0, "Direct app navigation required USB")
            try expect(session.entries.last?.status == .sent, "Unverified Bluetooth input was not reported as Sent")
            try expect(session.entries.last?.steps.isEmpty == true, "Direct input invented visual steps")
        }
    }

    private static func bluetoothOnlyRejectsAmbiguousVisualGoal() async throws {
        var captures = 0
        var dispatched: [PhonePromptAction] = []
        let runner = PhoneVisualRunner(capture: { after in
            captures += 1
            return try visualFrame(after: after)
        }, decide: { _, _, _ in .finished("Unexpected visual result") }, perform: { dispatched.append($0) },
            blockedReason: { "USB screen is unavailable" })
        let session = DevicePromptSession(deviceName: "Test Phone", blockedReason: { nil },
            planner: { try DevicePromptPlanner.plan($0) }, perform: { dispatched.append($0) },
            visualRunner: runner, visualBlockedReason: { "USB screen is unavailable" })
        let prompt = "Open Safari then tap Like"
        session.draft = prompt
        session.submit()
        try await waitUntil { !session.isRunning }
        try expect(dispatched.isEmpty && captures == 0, "An ambiguous visual goal executed a direct prefix without screen access")
        try expect(session.entries.last?.status == .needsInput, "An ambiguous Bluetooth-only goal was not rejected for clarification")
        try expect(session.draft == prompt, "The rejected visual goal was lost")
    }

    private static func cachedSessionAdoptsAvailableScreen() async throws {
        var screenReady = false
        var captures = 0
        var modelCalls = 0
        var planningCalls = 0
        var directActions: [PhonePromptAction] = []
        let reason: () -> String? = { screenReady ? nil : "Connect a USB screen" }
        let runner = PhoneVisualRunner(capture: { after in
            captures += 1
            return try visualFrame(after: after)
        }, decide: { _, _, _ in
            modelCalls += 1
            return .finished("The Home screen is visible.")
        }, perform: { _ in throw TestError.failure("Already-visible Home screen received unnecessary input") }, blockedReason: reason)
        let session = DevicePromptSession(deviceName: "Test Phone", blockedReason: { nil }, planner: {
            planningCalls += 1
            try expect($0 == "Show my main screen", "The fallback planner received the wrong request")
            return .init(actions: [.home])
        }, perform: { directActions.append($0) }, visualRunner: runner, visualBlockedReason: reason)
        session.draft = "Show my main screen"
        session.submit()
        try await waitUntil { !session.isRunning }
        try expect(session.entries.last?.status == .sent && captures == 0, "Initial cached session did not use Bluetooth-only input")
        screenReady = true
        session.draft = "Show my main screen"
        session.submit()
        try await waitUntil { !session.isRunning }
        try expect(session.entries.map(\.status) == [.sent, .completed], "The cached session did not adopt its newly available screen")
        try expect(captures == 1 && modelCalls == 1 && planningCalls == 1 && directActions == [.home], "Routing did not switch once screen access became available")
    }

    private static func lostScreenNeverFallsBack() async throws {
        var screenReady = true
        var captures = 0
        var visualActions: [PhonePromptAction] = []
        var directActions: [PhonePromptAction] = []
        var planningCalls = 0
        let reason: () -> String? = { screenReady ? nil : "The USB screen disconnected" }
        let runner = PhoneVisualRunner(capture: { after in
            captures += 1
            return try visualFrame(after: after)
        }, decide: { _, _, _ in .action(.home, reason: "Show the Home screen.") }, perform: {
            visualActions.append($0)
            screenReady = false
        }, blockedReason: reason)
        let session = DevicePromptSession(deviceName: "Test Phone", blockedReason: { nil }, planner: {
            planningCalls += 1
            return try DevicePromptPlanner.plan($0)
        }, perform: { directActions.append($0) }, visualRunner: runner, visualBlockedReason: reason)
        session.draft = "Open Safari"
        session.submit()
        try await waitUntil { !session.isRunning }
        try expect(session.entries.last?.status == .failed, "A lost visual screen did not stop the request")
        try expect(visualActions == [.home] && directActions.isEmpty && planningCalls == 0 && captures == 1, "A visual request silently fell back after losing its screen")
        try expect(session.entries.last?.message.contains("USB screen disconnected") == true, "The screen failure reason was hidden")
    }

    private static func routingIsChosenAtSubmission() async throws {
        var screenReady = true
        var captures = 0
        var planningCalls = 0
        var directActions: [PhonePromptAction] = []
        let reason: () -> String? = { screenReady ? nil : "The USB screen disconnected" }
        let runner = PhoneVisualRunner(capture: { after in
            captures += 1
            return try visualFrame(after: after)
        }, decide: { _, _, _ in .finished("The Home screen is visible.") },
            perform: { _ in throw TestError.failure("Unexpected visual input") }, blockedReason: reason)
        let session = DevicePromptSession(deviceName: "Test Phone", blockedReason: { nil }, planner: {
            planningCalls += 1
            return try DevicePromptPlanner.plan($0)
        }, perform: { directActions.append($0) }, visualRunner: runner, visualBlockedReason: reason)
        session.draft = "Open Safari"
        session.submit()
        // The task has not run yet, but the user's chosen route is already fixed.
        screenReady = false
        try await waitUntil { !session.isRunning }
        try expect(session.entries.last?.status == .failed && captures == 0, "A visual request continued after immediate screen loss")
        try expect(planningCalls == 0 && directActions.isEmpty, "The route changed between submission and task execution")
    }

    private static func literalCommandsBypassAvailableVision() async throws {
        let cases: [(String, [PhonePromptAction])] = [
            ("Go home", [.home]),
            ("Tap 50%, 25%", [.tap(0.5, 0.25)]),
            ("Type hello", [.typeText("hello")]),
            ("Press enter", [.press(.enter)]),
            ("Scroll down", [.swipe(.up)]),
            ("Go home then swipe up then press enter", [.home, .swipe(.up), .press(.enter)]),
        ]
        for (prompt, expected) in cases {
            var captures = 0
            var nativePlanningCalls = 0
            var dispatched: [PhonePromptAction] = []
            let runner = PhoneVisualRunner(capture: { after in
                captures += 1
                return try visualFrame(after: after)
            }, decide: { _, _, _ in
                throw TestError.failure("An exact command was reinterpreted by vision")
            }, perform: { _ in
                throw TestError.failure("An exact command used the visual driver")
            }, blockedReason: { nil })
            let session = DevicePromptSession(deviceName: "Test Phone", blockedReason: { nil }, planner: { _ in
                nativePlanningCalls += 1
                throw TestError.failure("An exact command was reinterpreted by the native text planner")
            }, perform: { dispatched.append($0) }, visualRunner: runner)
            try expect(session.canUseScreen, "The regression fixture must have an available screen")
            session.draft = prompt
            session.submit()
            try await waitUntil { !session.isRunning }
            try expect(dispatched == expected, "An exact command did not preserve its deterministic actions")
            try expect(captures == 0 && nativePlanningCalls == 0, "An exact command unnecessarily used a model")
            try expect(session.entries.last?.status == .sent && session.entries.last?.steps.isEmpty == true,
                "Direct input was falsely reported as visually verified")
        }
    }

    private static func appNavigationUsesVisionAndVerifiesResult() async throws {
        for prompt in ["Open Safari", "Search for cats", "Go home then Open Safari", "Search for cats then press enter"] {
            // Each goal is fully understood by the deterministic parser. Screen
            // availability must nevertheless route the entire goal to vision.
            _ = try DevicePromptPlanner.plan(prompt)
            let finalCapture = Gate()
            var captures = 0
            var decisions = 0
            var observedFrames: [PhoneScreenFrame] = []
            var visualActions: [PhonePromptAction] = []
            var directActions: [PhonePromptAction] = []
            var actionCompletedAt: Date?
            let runner = PhoneVisualRunner(capture: { after in
                captures += 1
                if captures == 2 {
                    try expect(actionCompletedAt.map { after >= $0 } == true,
                        "Navigation requested a result frame from before its input finished")
                    await finalCapture.wait()
                }
                let frame = try visualFrame(after: after)
                observedFrames.append(frame)
                return frame
            }, decide: { goal, frame, history in
                decisions += 1
                try expect(goal == prompt, "A compound app-navigation goal was split or rewritten")
                if decisions == 1 {
                    try expect(history.isEmpty && directActions.isEmpty,
                        "A deterministic prefix ran before visual navigation")
                    return .action(.tap(0.4, 0.3), reason: "Choose the target visible on this screen.")
                }
                try expect(history.count == 1 && frame.id != observedFrames[0].id,
                    "App navigation completed without a new result frame")
                try expect(actionCompletedAt.map { frame.capturedAt > $0 } == true,
                    "App navigation reused a frame captured before its input")
                return .finished("The requested destination is visible.")
            }, perform: {
                visualActions.append($0)
                actionCompletedAt = Date()
            }, blockedReason: { nil })
            let session = DevicePromptSession(deviceName: "Test Phone", blockedReason: { nil }, planner: { _ in
                throw TestError.failure("Parsed app navigation used the fallback text planner")
            }, perform: { directActions.append($0) }, visualRunner: runner)
            session.draft = prompt
            session.submit()
            try await waitUntil { finalCapture.isWaiting }
            try expect(visualActions == [.tap(0.4, 0.3)] && directActions.isEmpty,
                "Parsed app navigation sent the blind direct command sequence")
            try expect(session.isRunning && session.entries.last?.status == .running,
                "App navigation claimed completion before checking the resulting screen")
            finalCapture.release()
            try await waitUntil { !session.isRunning }
            try expect(captures == 2 && decisions == 2 && session.entries.last?.steps.count == 1,
                "App navigation skipped observation or repeated its input")
            try expect(session.entries.last?.status == .completed,
                "Visually verified app navigation was not marked Completed")
        }
    }

    private static func invalidVisualNavigationNeverRunsBlindPlan() async throws {
        var captures = 0
        var dispatched: [PhonePromptAction] = []
        let runner = PhoneVisualRunner(capture: { after in
            captures += 1
            return try visualFrame(after: after)
        }, decide: { _, _, _ in
            // A planner must return one atomic action. It cannot smuggle the
            // old unobserved app-opening sequence into the screen loop.
            .action(.openApp("Safari"), reason: "Open Safari")
        }, perform: { dispatched.append($0) }, blockedReason: { nil })
        let session = DevicePromptSession(deviceName: "Test Phone", blockedReason: { nil },
            planner: { try DevicePromptPlanner.plan($0) }, perform: { dispatched.append($0) }, visualRunner: runner)
        session.draft = "Open Safari"
        session.submit()
        try await waitUntil { !session.isRunning }
        try expect(captures == 1 && dispatched.isEmpty,
            "Invalid visual app navigation fell back to unverified direct input")
        try expect(session.entries.last?.status == .failed,
            "An invalid visual planner result was falsely reported as successful")
    }

    private static func unknownTailNeverExecutesKnownPrefix() async throws {
        var captures = 0
        var nativePlanningCalls = 0
        var dispatched: [PhonePromptAction] = []
        let runner = PhoneVisualRunner(capture: { after in
            captures += 1
            return try visualFrame(after: after)
        }, decide: { _, _, history in
            try expect(history.isEmpty, "A known prefix ran before the visual request began")
            return .needsInput("Which Display & Brightness control do you mean?")
        }, perform: { dispatched.append($0) }, blockedReason: { nil })
        let session = DevicePromptSession(deviceName: "Test Phone", blockedReason: { nil }, planner: { _ in
            nativePlanningCalls += 1
            return .init(actions: [.home])
        }, perform: { dispatched.append($0) }, visualRunner: runner)
        session.draft = "Go home then tap Display & Brightness"
        session.submit()
        try await waitUntil { !session.isRunning }
        try expect(captures == 1 && nativePlanningCalls == 0 && dispatched.isEmpty,
            "A mixed request executed its known prefix or selected two planning routes")
        try expect(session.entries.last?.status == .needsInput, "Visual clarification was lost")
    }

    private static func visualSession(_ runner: PhoneVisualRunner) -> DevicePromptSession {
        DevicePromptSession(deviceName: "Test Phone", blockedReason: { nil }, planner: { _ in
            throw TestError.failure("A visual request used the legacy planner")
        }, perform: { _ in
            throw TestError.failure("A visual request bypassed the visual runner")
        }, visualRunner: runner)
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

    private static func makeSession(actions: [PhonePromptAction], perform: @escaping (PhonePromptAction) async throws -> Void) -> DevicePromptSession {
        DevicePromptSession(deviceName: "Test Phone", blockedReason: { nil }, planner: { _ in .init(actions: actions) }, perform: perform)
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
