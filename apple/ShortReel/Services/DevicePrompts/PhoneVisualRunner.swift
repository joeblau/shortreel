import CoreGraphics
import Foundation
import ImageIO

/// Executes one input per observed screen. A model result never authorizes a
/// second input without another frame captured after the first input completed.
@MainActor
final class PhoneVisualRunner {
    private let capture: (Date) async throws -> PhoneScreenFrame
    private let decide: (String, PhoneScreenFrame, [PhoneVisionStep]) async throws -> PhoneVisionDecision
    private let perform: (PhonePromptAction) async throws -> Void
    private let blockedReason: () -> String?
    private let maximumSteps: Int
    private let maximumDuration: TimeInterval
    private let inspect: ((PhoneScreenFrame) async throws -> PhoneScreenObservation)?
    private let prepareCleanupAction: ((PhonePromptAction, PhoneScreenFrame) async throws -> PhonePromptAction)?
    private var isRunning = false

    init(capture: @escaping (Date) async throws -> PhoneScreenFrame,
         decide: @escaping (String, PhoneScreenFrame, [PhoneVisionStep]) async throws -> PhoneVisionDecision,
         perform: @escaping (PhonePromptAction) async throws -> Void,
         blockedReason: @escaping () -> String?,
         maximumSteps: Int = 30,
         maximumDuration: TimeInterval = 300,
         inspect: ((PhoneScreenFrame) async throws -> PhoneScreenObservation)? = nil,
         prepareCleanupAction: ((PhonePromptAction, PhoneScreenFrame) async throws -> PhonePromptAction)? = nil) {
        self.capture = capture
        self.decide = decide
        self.perform = perform
        self.blockedReason = blockedReason
        self.maximumSteps = min(maximumSteps, 30)
        self.maximumDuration = min(maximumDuration, 300)
        self.inspect = inspect
        self.prepareCleanupAction = prepareCleanupAction
    }

    /// A controlled input diagnostic, separate from model-chosen workflows.
    /// Leaves the switcher open for human inspection and never dismisses apps.
    func testAppSwitcher(onProgress: @escaping (String) -> Void,
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
            // Test the gesture directly from the observed screen; do not make
            // it depend on a separate Home gesture succeeding first.
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

    func run(goal: String,
             workflow: DeviceWorkflow? = nil,
             onProgress: @escaping (String) -> Void,
             onStep: @escaping (PhoneVisionStep) -> Void) async throws -> String {
        guard !isRunning else {
            throw PhoneVisionError.unavailable("A request is already running for this phone.")
        }
        let maximumSteps = workflow?.limits.maximumSteps ?? self.maximumSteps
        let maximumDuration = workflow?.limits.maximumDuration ?? self.maximumDuration
        guard maximumSteps > 0, maximumDuration.isFinite, maximumDuration > 0 else {
            throw PhoneVisionError.limitReached
        }
        let goal = goal.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !goal.isEmpty, goal.count <= DevicePromptPlanner.maximumPromptLength else {
            throw PhonePromptPlanningError.needsClarification("Describe what you want the phone to do in at most \(DevicePromptPlanner.maximumPromptLength) characters.")
        }
        if workflow == .clearHomeScreen, prepareCleanupAction == nil || inspect == nil {
            throw PhoneVisionError.unavailable("Home Screen cleanup needs screen inspection and removal checks.")
        }
        isRunning = true
        defer { isRunning = false }

        let deadline = ContinuousClock.now + .seconds(maximumDuration)
        var afterDate = Date()
        var sourceID: String?
        var frameIDs = Set<UUID>()
        var steps: [PhoneVisionStep] = []
        var previousInput: InputFingerprint?
        var previousPixels: [UInt8]?
        var repeatedInputs = 0

        for decisionNumber in 1...maximumSteps {
            try checkAvailability(deadline: deadline)
            onProgress("Reading the phone’s screen…")
            let requestedAfter = afterDate
            let frame = try await beforeDeadline(deadline) { [self] in
                try await capture(requestedAfter)
            }
            try checkAvailability(deadline: deadline)
            try validate(frame: frame, after: afterDate, sourceID: sourceID, usedIDs: frameIDs)
            if sourceID == nil { sourceID = frame.sourceID }
            frameIDs.insert(frame.id)

            if let last = steps.indices.last, let before = steps[last].beforeFrame {
                steps[last].afterFrame = frame
                steps[last].screenChanged = !Self.sameScreen(Self.screenFingerprint(before.cgImage), Self.screenFingerprint(frame.cgImage))
            }
            // Keep only two transitions in memory, scoped to this phone/run.
            for index in steps.indices.dropLast(2) {
                steps[index].beforeFrame = nil
                steps[index].afterFrame = nil
            }

            onProgress("Choosing the next action…")
            let history = steps
            var decision: PhoneVisionDecision
            do {
                decision = try await beforeDeadline(deadline) { [self] in
                    try await decide(goal, frame, history)
                }.validated()
            } catch let error as PhoneVisionError {
                // A malformed model response is a dud roll, not a failed goal:
                // ask once more with the same frame before giving up.
                guard case .invalidDecision = error else { throw error }
                onProgress("The model returned an unreadable action; asking again…")
                decision = try await beforeDeadline(deadline) { [self] in
                    try await decide(goal, frame, history)
                }.validated()
            }
            try checkAvailability(deadline: deadline)
            try checkFrameAge(frame)

            if workflow == .clearHomeScreen {
                let pixels = Self.screenFingerprint(frame.cgImage)
                let candidate: InputFingerprint?
                switch decision {
                case .action(let action, _): candidate = .action(action)
                case .wait: candidate = .wait
                default: candidate = nil
                }
                if let candidate, let previousInput, let previousPixels,
                   repeatedInputs >= 2, Self.similarInput(previousInput, candidate),
                   Self.sameScreen(previousPixels, pixels) {
                    onProgress("Checking another route through the Home Screen pages…")
                    decision = try await beforeDeadline(deadline) { [self] in
                        try await decide(goal + "\n\n" + DeviceWorkflow.cleanupStallRecovery, frame, history)
                    }.validated()
                }
                if case .finished = decision {
                    onProgress("Verifying one empty Home Screen page…")
                    let coverage = Self.hasCleanupSweep(steps)
                    let reviewGoal = goal + "\n\n" + DeviceWorkflow.cleanupCompletionReview
                        + (coverage ? "" : "\nNo sweep in both directions since the last layout change is recorded. Return a navigation action to establish coverage.")
                    decision = try await beforeDeadline(deadline) { [self] in
                        try await decide(reviewGoal, frame, history)
                    }.validated()
                    if case .finished = decision, !coverage {
                        throw PhonePromptPlanningError.needsClarification("Cleanup has not verified both page boundaries after the last layout change. One empty page does not prove that only one page remains.")
                    }
                }
                try checkAvailability(deadline: deadline)
                try checkFrameAge(frame)
            }

            switch decision {
            case .finished(let result):
                if workflow == .clearHomeScreen, let inspect {
                    let observation = try await beforeDeadline(deadline) { try await inspect(frame) }
                    try checkAvailability(deadline: deadline)
                    try checkFrameAge(frame)
                    guard observation.state == .home else {
                        throw PhonePromptPlanningError.needsClarification("Cleanup could not be verified on Home. " + observation.evidence)
                    }
                }
                onProgress("Checked the result on the phone’s screen.")
                return result
            case .needsInput(let explanation):
                throw PhonePromptPlanningError.needsClarification(explanation)
            case .action(let proposedAction, let proposedReason):
                var reason = proposedReason
                let action: PhonePromptAction
                if workflow == .clearHomeScreen, let prepareCleanupAction {
                    do {
                        action = try await beforeDeadline(deadline) { try await prepareCleanupAction(proposedAction, frame) }
                    } catch let error as PhonePromptPlanningError {
                        // A missed menu row is recoverable. Nothing was sent;
                        // replan once with the guard's observed controls, then
                        // subject the replacement to exactly the same guard.
                        try checkAvailability(deadline: deadline)
                        try checkFrameAge(frame)
                        onProgress("Locating the safe removal option…")
                        let instruction = "\n\nMENU CORRECTION: The proposed input was blocked. Inspect this same screenshot and choose one safe menu action. If Remove App is open, tap it, then inspect the next screenshot for Remove from Home Screen. Do not claim completion. Guard feedback: "
                        let available = max(0, DevicePromptPlanner.maximumPromptLength - goal.count - instruction.count)
                        let correctionGoal = goal + instruction + String(error.localizedDescription.prefix(available))
                        let correction = try await beforeDeadline(deadline) { [self] in
                            try await decide(correctionGoal, frame, history)
                        }.validated()
                        try checkAvailability(deadline: deadline)
                        try checkFrameAge(frame)
                        guard case .action(let correctedAction, let correctedReason) = correction else { throw error }
                        action = try await beforeDeadline(deadline) { try await prepareCleanupAction(correctedAction, frame) }
                        reason = correctedReason
                    }
                    _ = try PhoneVisionDecision.action(action, reason: reason).validated()
                    try checkAvailability(deadline: deadline)
                    try checkFrameAge(frame)
                } else {
                    action = proposedAction
                }
                try checkRepeatedInput(.action(action), pixels: Self.screenFingerprint(frame.cgImage),
                    previousInput: &previousInput, previousPixels: &previousPixels,
                    repeatedInputs: &repeatedInputs)
                let step = PhoneVisionStep(id: UUID(), number: decisionNumber,
                    action: description(of: action), detail: reason, capturedAt: frame.capturedAt,
                    input: action, beforeFrame: frame, progressNote: workflow == nil ? nil : reason)
                onProgress("Step \(decisionNumber): \(step.action)")
                var displayStep = step
                displayStep.beforeFrame = nil
                onStep(displayStep)
                // UI callbacks can cancel the task or change the selected phone.
                try checkAvailability(deadline: deadline)
                try checkFrameAge(frame)
                try await beforeDeadline(deadline) { [self] in try await perform(action) }
                try checkAvailability(deadline: deadline)
                steps.append(step)
                afterDate = Date()
            case .wait(let seconds, let reason):
                try checkRepeatedInput(.wait, pixels: Self.screenFingerprint(frame.cgImage),
                    previousInput: &previousInput, previousPixels: &previousPixels,
                    repeatedInputs: &repeatedInputs)
                let step = PhoneVisionStep(id: UUID(), number: decisionNumber,
                    action: "Wait for the screen", detail: reason, capturedAt: frame.capturedAt, beforeFrame: frame,
                    progressNote: workflow == nil ? nil : reason)
                onProgress("Waiting for the phone’s screen to change…")
                var displayStep = step
                displayStep.beforeFrame = nil
                onStep(displayStep)
                try checkAvailability(deadline: deadline)
                try await beforeDeadline(deadline) { try await Task.sleep(for: .seconds(seconds)) }
                try checkAvailability(deadline: deadline)
                steps.append(step)
                afterDate = Date()
            }
        }
        throw PhoneVisionError.limitReached
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
        // The encoder already bounds and decodes every published frame, so the
        // per-step check only guards identity and size invariants, plus a cheap
        // header-level JPEG completeness parse instead of a full re-decode.
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

    /// Navigation is necessary evidence, not sufficient proof of page count.
    /// The visual completion review still identifies the boundaries and contents.
    /// Any non-navigation input conservatively invalidates the previous sweep.
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
            // Require a post-action observation for each leg of the sweep.
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

    // Compare screen content, not JPEG bytes. Clock ticks, compression noise,
    // and the moving AssistiveTouch pointer must not reset a stalled tap loop.
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
        // Leave status-bar and home-indicator pixels out of the comparison.
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
        // validated() rejects these compound operations in the visual loop.
        case .openApp(let name): "Open \(name)"
        case .search: "Search"
        }
    }

    /// A stalled model/capture callback must not outlive the request's time limit
    /// or later deliver input after Stop. Tasks receive cancellation immediately;
    /// late results are ignored even if a provider ignores task cancellation.
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
