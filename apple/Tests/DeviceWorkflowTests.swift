import AppKit
import Foundation

// swiftc -swift-version 6 ShortReel/Services/DevicePrompts/{DevicePromptPlan,DevicePromptPlanner,DeviceWorkflow,PhoneVisionTypes,PhoneVisualRunner,DevicePromptSession,HomeScreenRemovalGuard}.swift Tests/DeviceWorkflowTests.swift -o /tmp/shortreel-workflow-tests
@main @MainActor
enum DeviceWorkflowTests {
    enum Failure: Error { case assertion(String) }

    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw Failure.assertion(message) }
    }

    static func main() async throws {
        try removalTargets()
        try widgetTargets()
        try await actualOCR()
        try await removalSequence()
        try await recoverRejectedMenuTap()
        try await editingRemovalSequence()
        try await longWorkflowAndSession()
        try await boundedWorkflow()
        try await rejectedRemovalNeverDispatches()
        try await completionRequiresHome()
        try await blockedAndMissingBrief()
        try await cancellationDuringGuard()
        try await completionReviewContinuesOntoSecondPage()
        try await completionNeedsPageCoverage()
        try await stalledBoundaryChangesDirection()
        try cleanupSweepInvalidation()
        try await slideshowConfiguration()
        print("Device workflow tests passed (17 scenarios)")
    }

    static func removalTargets() throws {
        let targets: [HomeScreenRemovalGuard.Target] = [
            .init(text: "Delete App", bounds: CGRect(x: 0.35, y: 0.40, width: 0.3, height: 0.03)),
            .init(text: "Remove from Home Screen", bounds: CGRect(x: 0.2, y: 0.50, width: 0.6, height: 0.03)),
            .init(text: "Cancel", bounds: CGRect(x: 0.4, y: 0.60, width: 0.2, height: 0.03))
        ]
        for action: PhonePromptAction in [.tap(0.5, 0.515), .tap(0.5, 0.615), .press(.escape)] {
            _ = try HomeScreenRemovalGuard.prepare(action, targets: targets)
        }
        for action: PhonePromptAction in [.tap(0.5, 0.415), .tap(0.5, 0.8), .press(.enter),
            .doubleTap(0.5, 0.515), .longPress(0.5, 0.515, seconds: 1), .swipe(.up)] {
            do {
                _ = try HomeScreenRemovalGuard.prepare(action, targets: targets)
                throw Failure.assertion("Allowed unsafe input: \(action)")
            } catch is PhonePromptPlanningError { }
        }
        _ = try HomeScreenRemovalGuard.prepare(.tap(0.5, 0.415), targets: [
            .init(text: "Remove App", bounds: targets[0].bounds)
        ])
        let menuLabel = CGRect(x: 0.25, y: 0.4, width: 0.2, height: 0.03)
        let grounded = try HomeScreenRemovalGuard.prepare(.tap(0.85, 0.415), targets: [
            .init(text: "Remove  App −", bounds: menuLabel)
        ])
        try expect(grounded == .tap(menuLabel.midX, menuLabel.midY), "Menu-row tap was not grounded to Remove App")
        do {
            _ = try HomeScreenRemovalGuard.prepare(.tap(0.9, 0.415), targets: targets)
            throw Failure.assertion("Off-label tap on Delete App row was allowed")
        } catch is PhonePromptPlanningError { }
        for label in ["Delete", "Offload App", "Hide and Require Face ID"] {
            do {
                _ = try HomeScreenRemovalGuard.prepare(.tap(0.5, 0.415), targets: [.init(text: label, bounds: targets[0].bounds)])
                throw Failure.assertion("Allowed \(label)")
            } catch is PhonePromptPlanningError { }
        }
    }

    static func widgetTargets() throws {
        let control = CGRect(x: 0.3, y: 0.5, width: 0.4, height: 0.03)
        for label in ["Remove Widget", "Remove Stack"] {
            let prepared = try HomeScreenRemovalGuard.prepare(.tap(0.9, 0.515), targets: [.init(text: label, bounds: control)])
            try expect(prepared == .tap(control.midX, control.midY), "Widget menu input was not grounded")
        }
        for heading in ["Remove “Weather” Widget?", "Remove Stack?"] {
            let prepared = try HomeScreenRemovalGuard.prepare(.tap(0.9, 0.515), targets: [
                .init(text: heading, bounds: CGRect(x: 0.2, y: 0.3, width: 0.6, height: 0.03)),
                .init(text: "Remove", bounds: control)
            ])
            try expect(prepared == .tap(control.midX, control.midY), "Widget confirmation was rejected")
        }
        for heading in ["Remove account?", "Remove App?"] {
            do {
                _ = try HomeScreenRemovalGuard.prepare(.tap(0.5, 0.515), targets: [
                    .init(text: heading, bounds: CGRect(x: 0.2, y: 0.3, width: 0.6, height: 0.03)),
                    .init(text: "Remove", bounds: control)
                ])
                throw Failure.assertion("Generic Remove allowed for \(heading)")
            } catch is PhonePromptPlanningError { }
        }
        let cancel = CGRect(x: 0.2, y: 0.5, width: 0.15, height: 0.03)
        let remove = CGRect(x: 0.65, y: 0.5, width: 0.15, height: 0.03)
        let alert: [HomeScreenRemovalGuard.Target] = [
            .init(text: "Remove “Weather” Widget?", bounds: CGRect(x: 0.2, y: 0.3, width: 0.6, height: 0.03)),
            .init(text: "Cancel", bounds: cancel), .init(text: "Remove", bounds: remove)
        ]
        let confirmation = try HomeScreenRemovalGuard.prepare(.tap(0.9, 0.515), targets: alert)
        try expect(confirmation == .tap(remove.midX, remove.midY),
            "Side-by-side widget confirmation was not grounded to Remove")
    }

    static func removalSequence() async throws {
        var captures = 0
        var inputs: [PhonePromptAction] = []
        let appLabel = CGRect(x: 0.25, y: 0.4, width: 0.2, height: 0.03)
        let homeLabel = CGRect(x: 0.2, y: 0.5, width: 0.6, height: 0.03)
        let expected: [PhonePromptAction] = [.tap(appLabel.midX, appLabel.midY), .tap(homeLabel.midX, homeLabel.midY), .swipe(.left), .swipe(.right)]
        let runner = PhoneVisualRunner(capture: { after in captures += 1; return frame(after: after) },
            decide: { _, _, history in
                try expect(history.compactMap(\.input) == inputs, "History did not record grounded inputs")
                switch captures {
                case 1: return .action(.tap(0.85, 0.415), reason: "Tap Remove App")
                case 2: return .action(.tap(0.9, 0.515), reason: "Tap Remove from Home Screen")
                case 3: return .action(.swipe(.left), reason: "Inspect App Library boundary")
                case 4: return .action(.swipe(.right), reason: "Return to the only empty Home page")
                default: return .finished("Home Screen verified")
                }
            }, perform: { action in
                try expect(captures == inputs.count + 1, "Removal actions did not wait for a fresh screenshot")
                inputs.append(action)
            }, blockedReason: { nil }, inspect: { _ in
                .init(state: .home, appCardsVisible: false, evidence: "Home Screen")
            }, prepareCleanupAction: { action, _ in
                if captures > 2 { return action }
                let targets: [HomeScreenRemovalGuard.Target] = captures == 1
                    ? [.init(text: "Remove App", bounds: appLabel)]
                    : [.init(text: "Delete App", bounds: appLabel), .init(text: "Remove from Home Screen", bounds: homeLabel)]
                return try HomeScreenRemovalGuard.prepare(action, targets: targets)
            })
        _ = try await runner.run(goal: DeviceWorkflow.clearHomeScreen.goal(), workflow: .clearHomeScreen,
            onProgress: { _ in }, onStep: { _ in })
        try expect(inputs == expected && captures == 5, "Remove App → Remove from Home Screen did not complete")
    }

    static func recoverRejectedMenuTap() async throws {
        let menu: [HomeScreenRemovalGuard.Target] = [
            .init(text: "• Remove App", bounds: CGRect(x: 0.2, y: 0.4, width: 0.3, height: 0.03)),
            .init(text: "Require Face ID", bounds: CGRect(x: 0.2, y: 0.45, width: 0.4, height: 0.03)),
            .init(text: "Edit Home Screen", bounds: CGRect(x: 0.2, y: 0.5, width: 0.4, height: 0.03))
        ]
        let dialog: [HomeScreenRemovalGuard.Target] = [
            .init(text: "Delete App", bounds: CGRect(x: 0.2, y: 0.4, width: 0.6, height: 0.03)),
            .init(text: "Remove from Home Screen", bounds: CGRect(x: 0.2, y: 0.5, width: 0.6, height: 0.03))
        ]
        var captures = 0, corrections = 0
        var sent: [PhonePromptAction] = []
        var recorded: [PhoneVisionStep] = []
        let runner = PhoneVisualRunner(capture: { after in captures += 1; return frame(after: after) },
            decide: { goal, _, history in
                try expect(goal.count <= DevicePromptPlanner.maximumPromptLength, "Correction exceeded provider limit")
                if goal.contains("MENU CORRECTION:") {
                    corrections += 1
                    try expect(goal.contains("Recognized controls") && goal.contains("x="), "No grounded menu feedback")
                    try expect(history.count == sent.count, "Rejected input leaked into executed history")
                    return .action(.tap(0.9, sent.isEmpty ? 0.415 : 0.515), reason: "Use recognized safe control")
                }
                switch sent.count {
                case 0: return .action(.tap(0.5, 0.7), reason: "Missed menu row")
                case 1: return .action(.tap(0.5, 0.415), reason: "Wrong dialog row")
                case 2: return .action(.swipe(.left), reason: "Inspect boundary")
                case 3: return .action(.swipe(.right), reason: "Return Home")
                default: return .finished("Verified single empty Home page")
                }
            }, perform: { action in
                try expect(captures == sent.count + 1, "Removal sequence skipped post-action capture")
                sent.append(action)
            }, blockedReason: { nil }, inspect: { _ in
                .init(state: .home, appCardsVisible: false, evidence: "Home")
            }, prepareCleanupAction: { action, _ in
                try HomeScreenRemovalGuard.prepare(action, targets: sent.isEmpty ? menu : sent.count == 1 ? dialog : [])
            })
        _ = try await runner.run(goal: DeviceWorkflow.clearHomeScreen.goal(), workflow: .clearHomeScreen,
            onProgress: { _ in }, onStep: { recorded.append($0) })
        try expect(corrections == 2 && captures == 5, "Safe menu recovery did not complete with fresh frames")
        try expect(sent == [.tap(menu[0].bounds.midX, menu[0].bounds.midY),
                            .tap(dialog[1].bounds.midX, dialog[1].bounds.midY), .swipe(.left), .swipe(.right)],
            "Rejected tap was dispatched or safe control was not grounded")
        try expect(recorded.prefix(2).allSatisfy { $0.detail == "Use recognized safe control" },
            "History retained the rejected action's reason")
    }

    static func editingRemovalSequence() async throws {
        let editLabel = CGRect(x: 0.2, y: 0.3, width: 0.6, height: 0.03)
        let removeLabel = CGRect(x: 0.2, y: 0.5, width: 0.6, height: 0.03)
        let menu: [HomeScreenRemovalGuard.Target] = [
            .init(text: "Edit Home Screen", bounds: editLabel),
            .init(text: "Remove App", bounds: removeLabel)
        ]
        let dialog: [HomeScreenRemovalGuard.Target] = [
            .init(text: "Delete App", bounds: editLabel),
            .init(text: "Remove from Home Screen", bounds: removeLabel)
        ]
        // Enter through the icon-menu fallback, then reuse editing mode for two
        // apps whose badge positions differ after the grid rearranges.
        let actions: [PhonePromptAction] = [
            .longPress(0.2, 0.2, seconds: 1), .tap(0.9, editLabel.midY),
            .tap(0.15, 0.18), .tap(0.9, removeLabel.midY),
            .tap(0.38, 0.18), .tap(0.9, removeLabel.midY),
            .tap(0.9, 0.05), .swipe(.left), .swipe(.right)
        ]
        var captures = 0
        var sent: [PhonePromptAction] = []
        let runner = PhoneVisualRunner(capture: { after in
            captures += 1
            return frame(after: after)
        }, decide: { _, _, history in
            try expect(history.compactMap(\.input) == sent, "Editing history lost grounded inputs")
            if history.count == actions.count { return .finished("One empty page verified") }
            return .action(actions[history.count], reason: "Inspect current editing badge or confirmation")
        }, perform: { action in
            try expect(captures == sent.count + 1, "Editing cleanup skipped a fresh screenshot")
            sent.append(action)
        }, blockedReason: { nil }, inspect: { _ in
            .init(state: .home, appCardsVisible: false, evidence: "Editing exited; Home visible")
        }, prepareCleanupAction: { action, _ in
            let targets = sent.count == 1 ? menu : [3, 5].contains(sent.count) ? dialog : []
            return try HomeScreenRemovalGuard.prepare(action, targets: targets)
        })
        _ = try await runner.run(goal: DeviceWorkflow.clearHomeScreen.goal(), workflow: .clearHomeScreen,
            onProgress: { _ in }, onStep: { _ in })
        var expected = actions
        expected[1] = .tap(editLabel.midX, editLabel.midY)
        expected[3] = .tap(removeLabel.midX, removeLabel.midY)
        expected[5] = .tap(removeLabel.midX, removeLabel.midY)
        try expect(sent == expected && captures == actions.count + 1,
            "Persistent editing cleanup did not ground menu controls and observe each removal")
    }

    static func actualOCR() async throws {
        let screenshot = frame(after: .distantPast, labels: [
            ("Delete App", 500), ("Remove from Home Screen", 400), ("Cancel", 300)
        ])
        // Labels are drawn with a bottom-left origin; inputs use top-left.
        let prepared = try await HomeScreenRemovalGuard.prepare(.tap(0.95, 1 - 415.0 / 1000), frame: screenshot)
        guard case .tap(let x, _) = prepared else { throw Failure.assertion("OCR did not return a tap") }
        try expect(abs(x - 0.5) < 0.03, "Real OCR failed to ground an off-label removal tap")
        do {
            _ = try await HomeScreenRemovalGuard.prepare(.tap(0.5, 1 - 515.0 / 1000), frame: screenshot)
            throw Failure.assertion("Real OCR allowed Delete App")
        } catch is PhonePromptPlanningError { }
    }

    static func longWorkflowAndSession() async throws {
        var decisions = 0, captures = 0, inputs = 0, inspections = 0, checks = 0
        let runner = PhoneVisualRunner(capture: { after in captures += 1; return frame(after: after) },
            decide: { goal, _, history in
                try expect(goal.hasPrefix(DeviceWorkflow.clearHomeScreen.goal()), "Lost cleanup goal")
                if goal.contains("COMPLETION REVIEW:") { return .finished("One empty page verified; allowed apps in Dock") }
                try expect(history.count == inputs, "Lost run history")
                try expect(history.allSatisfy { $0.progressNote != nil }, "Workflow did not preserve its progress notes")
                decisions += 1
                if decisions == 36 { return .action(.swipe(.left), reason: "Verify right boundary") }
                if decisions == 37 { return .action(.swipe(.right), reason: "Return Home") }
                return decisions > 37 ? .finished("All pages checked; only Instagram, YouTube, TikTok, and X remain.")
                    : .action(.tap(Double(decisions % 2) * 0.5 + 0.2, 0.3), reason: "Inspect page \(decisions)")
            }, perform: { _ in inputs += 1 }, blockedReason: { nil }, inspect: { _ in
                inspections += 1
                return .init(state: .home, appCardsVisible: false, evidence: "Home with the allowed apps")
            }, prepareCleanupAction: { action, _ in checks += 1; return action })
        let session = DevicePromptSession(deviceName: "SR1", blockedReason: { nil }, visualRunner: runner)
        session.draft = "Keep my unfinished message"
        session.submit(workflow: .clearHomeScreen)
        session.submit(workflow: .clearHomeScreen)
        try await finish(session)
        try expect(session.entries.count == 1, "Duplicate task started")
        try expect(session.entries.last?.status == .completed, "Long workflow did not finish")
        try expect(session.entries.last?.workflow == .clearHomeScreen, "Missing workflow identity")
        try expect(session.draft == "Keep my unfinished message", "Workflow overwrote composer draft")
        try expect(inputs == 37 && captures == 38 && checks == inputs && inspections == 1,
            "Cleanup lost capture/action/verification order or hit the ordinary 30-step limit")
    }

    static func boundedWorkflow() async throws {
        var decisions = 0, inputs = 0
        let runner = PhoneVisualRunner(capture: { frame(after: $0) }, decide: { _, _, _ in
            decisions += 1
            return .action(.tap(Double(decisions % 2) * 0.5 + 0.2, 0.3), reason: "Keep working")
        }, perform: { _ in inputs += 1 }, blockedReason: { nil })
        do {
            _ = try await runner.run(goal: "View videos", workflow: .warmUp, onProgress: { _ in }, onStep: { _ in })
            throw Failure.assertion("Workflow was unbounded")
        } catch PhoneVisionError.limitReached { }
        try expect(inputs == 300, "Workflow did not stop at its decision limit")
    }

    static func rejectedRemovalNeverDispatches() async throws {
        var inputs = 0, checks = 0
        let runner = PhoneVisualRunner(capture: { frame(after: $0) },
            decide: { _, _, _ in .action(.tap(0.5, 0.5), reason: "Remove this app") },
            perform: { _ in inputs += 1 }, blockedReason: { nil }, inspect: { _ in
                .init(state: .home, appCardsVisible: false, evidence: "Home")
            }, prepareCleanupAction: { _, _ in checks += 1; throw PhonePromptPlanningError.needsClarification("Unsafe removal") })
        let session = DevicePromptSession(deviceName: "SR1", blockedReason: { nil }, visualRunner: runner)
        session.submit(workflow: .clearHomeScreen)
        try await finish(session)
        try expect(inputs == 0 && checks == 2 && session.entries.last?.status == .needsInput, "Rejected input was sent or recovery was unbounded")
        try expect(session.draft.isEmpty, "Cleanup instructions leaked into composer after failure")
    }

    static func completionRequiresHome() async throws {
        for state: PhoneScreenObservation.State in [.homeEditing, .dialog, .foregroundApp] {
            let runner = PhoneVisualRunner(capture: { frame(after: $0) }, decide: { _, _, history in
                    if history.isEmpty { return .action(.swipe(.left), reason: "Inspect boundary") }
                    if history.count == 1 { return .action(.swipe(.right), reason: "Return Home") }
                    return .finished("Done")
                }, perform: { _ in }, blockedReason: { nil }, inspect: { _ in
                    .init(state: state, appCardsVisible: false, evidence: "Not finished on Home")
                }, prepareCleanupAction: { action, _ in action })
            let session = DevicePromptSession(deviceName: "SR1", blockedReason: { nil }, visualRunner: runner)
            session.submit(workflow: .clearHomeScreen)
            try await finish(session)
            try expect(session.entries.last?.status == .needsInput, "Completed on \(state)")
        }
    }

    static func blockedAndMissingBrief() async throws {
        let blocked = DevicePromptSession(deviceName: "SR1", blockedReason: { "Connect input" })
        blocked.draft = "Draft"
        blocked.submit(workflow: .clearHomeScreen)
        try expect(!blocked.isRunning && blocked.entries.last?.message == "Connect input", "Ignored blocked input")
        try expect(blocked.draft == "Draft", "Blocked workflow lost draft")
        let session = DevicePromptSession(deviceName: "SR2", blockedReason: { nil })
        for workflow: DeviceWorkflow in [.warmUp, .createContent] {
            session.submit(workflow: workflow)
            try expect(session.entries.last?.status == .needsInput && !session.isRunning, "Ran without a brief")
        }
        let cleanup = DeviceWorkflow.clearHomeScreen.goal()
        try expect((cleanup + DeviceWorkflow.cleanupCompletionReview + String(repeating: " ", count: 150)).count < DevicePromptPlanner.maximumPromptLength,
            "Completion review exceeds provider goal limit")
        try expect((cleanup + DeviceWorkflow.cleanupStallRecovery).count < DevicePromptPlanner.maximumPromptLength,
            "Recovery exceeds provider goal limit")
        for workflow in DeviceWorkflow.allCases {
            try expect(workflow.goal().count < DevicePromptPlanner.maximumPromptLength, "Preset exceeds model goal limit")
        }
    }

    static func cancellationDuringGuard() async throws {
        var checking = false, inputs = 0
        let runner = PhoneVisualRunner(capture: { frame(after: $0) },
            decide: { _, _, _ in .action(.tap(0.5, 0.5), reason: "Remove app") },
            perform: { _ in inputs += 1 }, blockedReason: { nil }, inspect: { _ in
                .init(state: .home, appCardsVisible: false, evidence: "Home")
            }, prepareCleanupAction: { action, _ in checking = true; try await Task.sleep(for: .seconds(10)); return action })
        let session = DevicePromptSession(deviceName: "SR1", blockedReason: { nil }, visualRunner: runner)
        session.submit(workflow: .clearHomeScreen)
        let deadline = Date().addingTimeInterval(3)
        while !checking && Date() < deadline { try await Task.sleep(for: .milliseconds(1)) }
        try expect(checking, "Guard never started")
        session.cancel()
        try await finish(session)
        try expect(inputs == 0 && session.entries.last?.status == .cancelled, "Stop allowed a pending removal")
    }

    static func completionReviewContinuesOntoSecondPage() async throws {
        var inputs: [PhonePromptAction] = []
        var reviews = 0
        let runner = PhoneVisualRunner(capture: { frame(after: $0) }, decide: { goal, _, history in
            if goal.contains("COMPLETION REVIEW:") {
                reviews += 1
                if reviews == 1 {
                    return .action(.swipe(.left), reason: "An empty first page is not proof; inspect the page to the right")
                }
                return .finished("One empty Home page and the four allowed Dock apps verified")
            }
            switch history.count {
            case 0: return .finished("First page is empty")
            case 1: return .action(.tap(0.5, 0.5), reason: "Second page has content; continue cleanup")
            case 2: return .action(.swipe(.left), reason: "After cleanup, verify App Library boundary")
            case 3: return .action(.swipe(.right), reason: "Return to the sole empty Home page")
            default: return .finished("Cleanup done")
            }
        }, perform: { inputs.append($0) }, blockedReason: { nil }, inspect: { _ in
            .init(state: .home, appCardsVisible: false, evidence: "Home")
        }, prepareCleanupAction: { action, _ in action })
        _ = try await runner.run(goal: DeviceWorkflow.clearHomeScreen.goal(), workflow: .clearHomeScreen,
            onProgress: { _ in }, onStep: { _ in })
        try expect(reviews == 2 && inputs == [.swipe(.left), .tap(0.5, 0.5), .swipe(.left), .swipe(.right)],
            "Stopped on the first empty page instead of reviewing and cleaning the second")
    }

    static func completionNeedsPageCoverage() async throws {
        let runner = PhoneVisualRunner(capture: { frame(after: $0) }, decide: { _, _, _ in .finished("Home is empty") },
            perform: { _ in throw Failure.assertion("Unexpected input") }, blockedReason: { nil }, inspect: { _ in
                .init(state: .home, appCardsVisible: false, evidence: "Empty Home page")
            }, prepareCleanupAction: { action, _ in action })
        do {
            _ = try await runner.run(goal: DeviceWorkflow.clearHomeScreen.goal(), workflow: .clearHomeScreen,
                onProgress: { _ in }, onStep: { _ in })
            throw Failure.assertion("Accepted one screenshot without page coverage")
        } catch PhonePromptPlanningError.needsClarification(let message) {
            try expect(message.contains("page boundaries"), "Missing page verification explanation")
        }
    }

    static func stalledBoundaryChangesDirection() async throws {
        var inputs: [PhonePromptAction] = []
        var recoveries = 0
        let runner = PhoneVisualRunner(capture: { frame(after: $0) }, decide: { goal, _, history in
            if goal.contains("NAVIGATION RECOVERY:") {
                recoveries += 1
                return .action(.swipe(.right), reason: "The left boundary attempt did not move; inspect the opposite direction")
            }
            if history.count < 3 { return .action(.swipe(.left), reason: "Check next page") }
            return .finished("One empty page verified")
        }, perform: { inputs.append($0) }, blockedReason: { nil }, inspect: { _ in
            .init(state: .home, appCardsVisible: false, evidence: "Home")
        }, prepareCleanupAction: { action, _ in action })
        _ = try await runner.run(goal: DeviceWorkflow.clearHomeScreen.goal(), workflow: .clearHomeScreen,
            onProgress: { _ in }, onStep: { _ in })
        try expect(recoveries == 1 && inputs == [.swipe(.left), .swipe(.left), .swipe(.right)],
            "Boundary navigation failed without trying a different input")
    }

    static func cleanupSweepInvalidation() throws {
        func step(_ action: PhonePromptAction) -> PhoneVisionStep {
            .init(id: UUID(), number: 1, action: "Input", detail: "Observed", capturedAt: Date(),
                input: action, screenChanged: true)
        }
        let sweep = [step(.swipe(.left)), step(.swipe(.right))]
        try expect(PhoneVisualRunner.hasCleanupSweep(sweep), "Lost two-direction sweep")
        try expect(!PhoneVisualRunner.hasCleanupSweep(sweep + [step(.tap(0.5, 0.5)), step(.swipe(.right))]),
            "Used page coverage from before a possible layout change")
        try expect(!PhoneVisualRunner.hasCleanupSweep([step(.swipe(.down)), step(.swipe(.right))]),
            "Vertical gesture counted as page coverage")
    }

    static func slideshowConfiguration() async throws {
        var configuration = SlideshowConfiguration()
        try expect(configuration.validationMessage != nil, "Accepted an empty slideshow brief")
        configuration.destination = " Instagram "
        configuration.topic = " A weekend in the mountains "
        configuration.photoSelection = "Album: Hiking. First six photos, oldest first."
        configuration.slideCount = 6
        configuration.caption = "A weekend worth remembering."
        configuration.instructions = "Add a short location label to each slide."
        try expect(configuration.validationMessage == nil, "Rejected a complete slideshow")
        let valid = configuration
        configuration.slideCount = 1
        try expect(configuration.validationMessage != nil, "Accepted a one-slide slideshow")
        configuration = valid
        configuration.photoSelection = " \n "
        try expect(configuration.validationMessage != nil, "Accepted missing photo selection")
        configuration = valid
        configuration.instructions = String(repeating: "a", count: DevicePromptPlanner.maximumPromptLength)
        try expect(configuration.validationMessage != nil, "Accepted details beyond the model goal limit")

        let brief = valid.brief
        var receivedGoal = ""
        let runner = PhoneVisualRunner(capture: { frame(after: $0) }, decide: { goal, _, _ in
            receivedGoal = goal
            return .finished("Slideshow draft saved")
        }, perform: { _ in throw Failure.assertion("Unexpected test input") }, blockedReason: { nil })
        let session = DevicePromptSession(deviceName: "SR1", blockedReason: { nil }, visualRunner: runner)
        session.submit(workflow: .createContent, details: brief)
        try await finish(session)
        try expect(session.entries.last?.status == .completed && session.entries.last?.workflow == .createContent,
            "Slideshow did not use the content workflow")
        for detail in ["Destination app: Instagram", "Topic: A weekend in the mountains", "Number of slides: 6",
                       valid.photoSelection, valid.caption, valid.instructions, "Save as a draft only."] {
            try expect(receivedGoal.contains(detail), "Content workflow lost slideshow setting: \(detail)")
        }
    }

    static func finish(_ session: DevicePromptSession) async throws {
        let deadline = Date().addingTimeInterval(15)
        while session.isRunning && Date() < deadline { try await Task.sleep(for: .milliseconds(1)) }
        try expect(!session.isRunning, "Session did not finish")
    }

    static func frame(after: Date, labels: [(String, CGFloat)] = []) -> PhoneScreenFrame {
        let width = labels.isEmpty ? 8 : 500, height = labels.isEmpty ? 12 : 1000
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        for (label, y) in labels {
            let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 28), .foregroundColor: NSColor.black]
            let size = (label as NSString).size(withAttributes: attributes)
            (label as NSString).draw(at: CGPoint(x: (500 - size.width) / 2, y: y), withAttributes: attributes)
        }
        NSGraphicsContext.restoreGraphicsState()
        let image = context.makeImage()!
        return .init(id: UUID(), capturedAt: max(Date(), after.addingTimeInterval(0.000_001)), pixelWidth: width,
            pixelHeight: height, jpegData: NSBitmapImageRep(cgImage: image).representation(using: .jpeg, properties: [:])!,
            cgImage: image, sourceID: "SR1")
    }
}
