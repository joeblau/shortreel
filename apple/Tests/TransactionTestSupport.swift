import Foundation
import CoreGraphics
import ImageIO

@MainActor enum TransactionTestSupport {
    enum Failure: Error { case assertion(String), injected }
    static func expect(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
        if try !value() { throw Failure.assertion(message) }
    }
    static func rejects(_ operation: () async throws -> Void) async throws {
        do { try await operation() }
        catch is Failure { throw Failure.assertion("Unexpected test failure") }
        catch { return }
        throw Failure.assertion("Expected rejection")
    }
    @MainActor final class Gate {
        var waiting = false
        var continuation: CheckedContinuation<Void, Never>?
        func wait() async { waiting = true; await withCheckedContinuation { continuation = $0 } }
        func release() { continuation?.resume(); continuation = nil }
    }
    static func until(_ predicate: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(3)
        while !predicate() {
            guard ContinuousClock.now < deadline else { throw Failure.assertion("Timed out") }
            try await Task.sleep(for: .milliseconds(1))
        }
    }
    static func frame(after: Date, id: UUID = UUID(), source: String = "Phone", stale: Bool = false, malformed: Bool = false) throws -> PhoneScreenFrame {
        let context = CGContext(data: nil, width: 8, height: 12, bitsPerComponent: 8, bytesPerRow: 32,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.setFillColor(red: 0.2, green: 0.3, blue: 0.4, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 8, height: 12))
        let image = context.makeImage()!
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw Failure.assertion("JPEG fixture failed") }
        return .init(id: id, capturedAt: stale ? after : max(Date(), after.addingTimeInterval(0.000_001)),
            pixelWidth: 8, pixelHeight: 12, jpegData: malformed ? Data([1, 2]) : data as Data, cgImage: image, sourceID: source)
    }
    static func plan(command: PhoneTransactionPlan.Command? = .init(kind: .home, value: "", destination: "", seconds: 0),
                     phase: String = "task", next: String = "$done", maximumVisits: Int = 3) -> PhoneTransactionPlan {
        .init(version: 1, phases: [.init(id: phase, entry: "start", states: [.init(id: "start", maximumVisits: maximumVisits,
            branches: [.init(id: "go", condition: "The app is visible", command: command,
                expected: command == nil ? "" : "The Home screen is visible", next: next)])])])
    }
    @MainActor final class Rig {
        var plan = TransactionTestSupport.plan()
        var compileGoals: [String] = []
        var actions: [PhonePromptAction] = []
        var questions: [PhoneTransactionQuestion] = []
        var captures = 0
        var locatorCalls = 0
        var trace: [String] = []
        var captureOverride: ((Date) async throws -> PhoneScreenFrame)?
        var compileOverride: ((String, WarmUpScript?) async throws -> PhoneTransactionPlan)?
        var classifyOverride: ((PhoneTransactionQuestion) async throws -> String?)?
        var locate: (String, PhoneScreenFrame, [PhoneVisionStep]) async throws -> PhoneVisionDecision = { _, _, _ in .action(.tap(0.5, 0.5), reason: "Located") }
        var onPerform: ((PhonePromptAction) async throws -> Void)?
        var blocked: String?
        var duration = 30.0
        var stepLimit = 30
        var accountOutcome: WarmUpAccountDecision.Outcome = .matches
        var failure: WarmUpFailureDecision?
        var accountCalls = 0
        var accountObservations: [PhoneScreenObservation] = []
        var budget = WarmUpStepBudget(maxPlannerDecisions: 30, maxSeconds: 30)
        var cleanup: ((PhonePromptAction, PhoneScreenFrame) async throws -> PhonePromptAction)?
        var inspectOverride: ((PhoneScreenFrame) async throws -> PhoneScreenObservation)?
        var observeOverride: ((PhoneScreenFrame, String) async throws -> PhoneScreenObservation)?
        var readTextOverride: ((PhoneScreenFrame, String) -> PhonePlaybackTracker.Observation)?
        var budgetOverride: ((WarmUpScript, WarmUpScript.StepID) -> WarmUpStepBudget?)?
        func runner() -> PhoneVisualRunner {
            PhoneVisualRunner(capture: { after in
                self.captures += 1; self.trace.append("capture")
                return try await self.captureOverride?(after) ?? TransactionTestSupport.frame(after: after)
            }, decide: { goal, frame, history in
                self.locatorCalls += 1
                return try await self.locate(goal, frame, history)
            }, perform: { action in
                self.trace.append("perform"); self.actions.append(action)
                try await self.onPerform?(action)
            }, blockedReason: { self.blocked }, maximumSteps: stepLimit, maximumDuration: duration,
               inspect: { frame in
                if let inspect = self.inspectOverride { return try await inspect(frame) }
                return .init(state: .home, appCardsVisible: false, evidence: "Home is visible")
            }, observe: { frame, question in
                if let observe = self.observeOverride { return try await observe(frame, question) }
                if let inspect = self.inspectOverride { return try await inspect(frame) }
                return .init(state: .home, appCardsVisible: false, evidence: "Home is visible")
            }, prepareCleanupAction: { action, frame in try await self.cleanup?(action, frame) ?? action }, readText: { frame, platform in
                self.readTextOverride?(frame, platform) ?? .init(sourceID: frame.sourceID, capturedAt: frame.capturedAt, platform: platform, regions: [])
            }, validateSubmissionAction: { _, _, _ in }, classifyAccount: { _, observation, _, _ in
                self.accountCalls += 1
                self.accountObservations.append(observation)
                return .init(outcome: self.accountOutcome, evidence: self.accountOutcome.rawValue,
                    probabilities: [:], margin: 1, threshold: 0.12, promptHash: "fixture")
            }, classifyFailure: { _, _, step, _ in
                self.failure ?? .init(stepID: step.rawValue, failureModeID: nil, uncertain: false,
                    terminal: false, detection: "", recovery: "", evidence: "none", probabilities: [:], margin: 1, threshold: 0.12, promptHash: "fixture")
            }, stepBudget: { script, step in self.budgetOverride?(script, step) ?? self.budget }, compile: { goal, script, progress in
                self.trace.append("compile"); self.compileGoals.append(goal)
                if let compile = self.compileOverride { return try await compile(goal, script) }
                return self.plan
            }, classify: { question in
                self.trace.append("classify"); self.questions.append(question)
                if let classify = self.classifyOverride { return try await classify(question) }
                return question.id.hasSuffix(".verify") ? "confirmed" : "go"
            })
        }
        @discardableResult func run(workflow: DeviceWorkflow? = nil, script: WarmUpScript? = nil,
                                   checkpoint: @escaping (PhoneTransactionCheckpoint) throws -> Void = { _ in }) async throws -> String {
            try await runner().run(goal: script == nil ? "Go home" : "Platform: TikTok\nAccount check: Verify exactly @fixture, before browsing.", workflow: workflow,
                warmUpScript: script, onTransactionPlan: { _ in self.trace.append("savePlan") },
                onTransactionCheckpoint: { value in self.trace.append(value.status.rawValue); try checkpoint(value) },
                onProgress: { _ in }, onStep: { _ in })
        }
    }
    static func journal() -> DeviceRunJournal {
        .init(deviceIdentifier: "phone", directory: FileManager.default.temporaryDirectory.appendingPathComponent("shortreel-test-" + UUID().uuidString))
    }
}
