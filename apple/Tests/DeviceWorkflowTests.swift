import AppKit
import Foundation

// Run Tests/run-transactions.sh from apple/.
@main @MainActor enum DeviceWorkflowTests {
    typealias T = TransactionTestSupport
    enum Failure: Error { case assertion(String) }
    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw Failure.assertion(message) }
    }
    static func main() async throws {
        try removalTargets()
        try widgetTargets()
        try await actualOCR()
        try await blockedAndMissingBrief()
        try cleanupSweepInvalidation()
        try await slideshowConfiguration()
        try await fixedCleanupSequence()
        try await unsafeRemovalAndCancellation()
        try await stageBudget()
        print("Stage workflow tests passed (removal guards, OCR, drafts, page sweep, cancellation, budgets)")
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
        try expect(cleanup.count < DevicePromptPlanner.maximumPromptLength, "Cleanup brief exceeds request limit")
        for workflow in DeviceWorkflow.allCases {
            try expect(workflow.goal().count < DevicePromptPlanner.maximumPromptLength, "Preset exceeds model goal limit")
        }
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
        let rig = T.Rig(); rig.plan = T.plan(command: nil)
        let session = DevicePromptSession(deviceName: "SR1", blockedReason: { nil }, visualRunner: rig.runner())
        session.submit(workflow: .createContent, details: brief)
        try await finish(session)
        try expect(session.entries.last?.status == .completed && session.entries.last?.workflow == .createContent,
            "Slideshow did not use the content workflow")
        for detail in ["Destination app: Instagram", "Topic: A weekend in the mountains", "Number of slides: 6",
                       valid.photoSelection, valid.caption, valid.instructions, "Save as a draft only."] {
            try expect(rig.compileGoals.first?.contains(detail) == true, "Content workflow lost slideshow setting: \(detail)")
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
    static func cleanupPlan() -> PhoneTransactionPlan {
        let commands: [PhoneTransactionPlan.Command] = [
            .init(kind: .tap, value: "Remove App", destination: "", seconds: 0),
            .init(kind: .tap, value: "Remove from Home Screen", destination: "", seconds: 0),
            .init(kind: .swipe, value: "left", destination: "", seconds: 0),
            .init(kind: .swipe, value: "right", destination: "", seconds: 0)]
        return .init(version: 1, phases: [.init(id: "cleanup", entry: "s0", states: commands.enumerated().map { index, command in
            .init(id: "s\(index)", maximumVisits: 2, branches: [.init(id: "go", condition: "Expected cleanup screen is visible",
                command: command, expected: "Required cleanup result is visible", next: index == 3 ? "$done" : "s\(index + 1)")])
        })])
    }
    static func fixedCleanupSequence() async throws {
        let rig = T.Rig(); rig.plan = cleanupPlan()
        rig.cleanup = { action, _ in
            if case .tap = action { return .tap(0.4, 0.6) }
            return action
        }
        _ = try await rig.run(workflow: .clearHomeScreen)
        try expect(rig.actions == [.tap(0.4, 0.6), .tap(0.4, 0.6), .swipe(.left), .swipe(.right)] && rig.captures == 8,
            "Cleanup did not verify every input or preserve guard-grounded coordinates")
        let noSweep = T.Rig(); noSweep.plan = T.plan(command: nil)
        try await T.rejects { _ = try await noSweep.run(workflow: .clearHomeScreen) }
        let wrongScreen = T.Rig(); wrongScreen.plan = cleanupPlan()
        wrongScreen.inspectOverride = { _ in .init(state: .homeEditing, appCardsVisible: false, evidence: "Editing") }
        try await T.rejects { _ = try await wrongScreen.run(workflow: .clearHomeScreen) }
    }
    static func unsafeRemovalAndCancellation() async throws {
        let unsafe = T.Rig(); unsafe.plan = cleanupPlan()
        unsafe.cleanup = { action, _ in
            try HomeScreenRemovalGuard.prepare(action, targets: [.init(text: "Delete App", bounds: CGRect(x: 0.4, y: 0.4, width: 0.2, height: 0.2))])
        }
        try await T.rejects { _ = try await unsafe.run(workflow: .clearHomeScreen) }
        try expect(unsafe.actions.isEmpty, "Unsafe removal reached device")
        let rig = T.Rig(); rig.plan = cleanupPlan(); let gate = T.Gate()
        rig.cleanup = { action, _ in await gate.wait(); return action }
        let task = Task { try await rig.run(workflow: .clearHomeScreen) }
        try await T.until { gate.waiting }; task.cancel()
        try await T.rejects { _ = try await task.value }; gate.release()
        try expect(rig.actions.isEmpty, "Cancelled guard dispatched")
    }
    static func stageBudget() async throws {
        let plan = PhoneTransactionPlan(version: 1, phases: [.init(id: "draft", entry: "s0", states: (0..<20).map { index in
            .init(id: "s\(index)", maximumVisits: 1, branches: [.init(id: "go", condition: "Draft field is focused",
                command: .init(kind: .typeText, value: "\(index)", destination: "", seconds: 0), expected: "Text is visible",
                next: index == 19 ? "$done" : "s\(index + 1)")])
        })])
        let rig = T.Rig(); rig.plan = plan
        _ = try await rig.run(workflow: .createContent)
        try expect(rig.actions.count == 20 && rig.captures == 40, "Stage inherited short Agent budget")
        let agent = T.Rig(); agent.plan = plan
        try await T.rejects { _ = try await agent.run() }
        try expect(agent.captures == 30, "Agent run budget was ignored")
    }

}
