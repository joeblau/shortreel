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
    private var isRunning = false

    init(capture: @escaping (Date) async throws -> PhoneScreenFrame,
         decide: @escaping (String, PhoneScreenFrame, [PhoneVisionStep]) async throws -> PhoneVisionDecision,
         perform: @escaping (PhonePromptAction) async throws -> Void,
         blockedReason: @escaping () -> String?,
         maximumSteps: Int = 30,
         maximumDuration: TimeInterval = 300) {
        self.capture = capture
        self.decide = decide
        self.perform = perform
        self.blockedReason = blockedReason
        self.maximumSteps = min(maximumSteps, 30)
        self.maximumDuration = min(maximumDuration, 300)
    }

    func run(goal: String,
             onProgress: @escaping (String) -> Void,
             onStep: @escaping (PhoneVisionStep) -> Void) async throws -> String {
        guard !isRunning else {
            throw PhoneVisionError.unavailable("A request is already running for this phone.")
        }
        guard maximumSteps > 0, maximumDuration.isFinite, maximumDuration > 0 else {
            throw PhoneVisionError.limitReached
        }
        let goal = goal.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !goal.isEmpty, goal.count <= DevicePromptPlanner.maximumPromptLength else {
            throw PhonePromptPlanningError.needsClarification("Describe what you want the phone to do in at most \(DevicePromptPlanner.maximumPromptLength) characters.")
        }
        isRunning = true
        defer { isRunning = false }

        let deadline = ContinuousClock.now + .seconds(maximumDuration)
        var afterDate = Date()
        var sourceID: String?
        var frameIDs = Set<UUID>()
        var steps: [PhoneVisionStep] = []
        var previousInput: InputFingerprint?
        var previousJPEG: Data?
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

            onProgress("Choosing the next action…")
            let history = steps
            let decision = try await beforeDeadline(deadline) { [self] in
                try await decide(goal, frame, history)
            }.validated()
            try checkAvailability(deadline: deadline)
            try checkFrameAge(frame)

            switch decision {
            case .finished(let result):
                onProgress("Checked the result on the phone’s screen.")
                return result
            case .needsInput(let explanation):
                throw PhonePromptPlanningError.needsClarification(explanation)
            case .action(let action, let reason):
                try checkRepeatedInput(.action(action), jpeg: frame.jpegData,
                    previousInput: &previousInput, previousJPEG: &previousJPEG,
                    repeatedInputs: &repeatedInputs)
                let step = PhoneVisionStep(id: UUID(), number: decisionNumber,
                    action: description(of: action), detail: reason, capturedAt: frame.capturedAt)
                onProgress("Step \(decisionNumber): \(step.action)")
                onStep(step)
                // UI callbacks can cancel the task or change the selected phone.
                try checkAvailability(deadline: deadline)
                try checkFrameAge(frame)
                try await beforeDeadline(deadline) { [self] in try await perform(action) }
                try checkAvailability(deadline: deadline)
                steps.append(step)
                afterDate = Date()
            case .wait(let seconds, let reason):
                try checkRepeatedInput(.wait, jpeg: frame.jpegData,
                    previousInput: &previousInput, previousJPEG: &previousJPEG,
                    repeatedInputs: &repeatedInputs)
                let step = PhoneVisionStep(id: UUID(), number: decisionNumber,
                    action: "Wait for the screen", detail: reason, capturedAt: frame.capturedAt)
                onProgress("Waiting for the phone’s screen to change…")
                onStep(step)
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
        guard !frame.sourceID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              (1...8_192).contains(frame.pixelWidth), (1...8_192).contains(frame.pixelHeight),
              frame.pixelWidth * frame.pixelHeight <= 32_000_000,
              !frame.jpegData.isEmpty, frame.jpegData.count <= 10_000_000,
              let imageSource = CGImageSourceCreateWithData(frame.jpegData as CFData, nil),
              CGImageSourceGetType(imageSource) as String? == "public.jpeg",
              CGImageSourceGetCount(imageSource) == 1,
              CGImageSourceGetStatus(imageSource) == .statusComplete,
              let properties = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [CFString: Any],
              (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue == frame.pixelWidth,
              (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue == frame.pixelHeight,
              CGImageSourceCreateImageAtIndex(imageSource, 0, [kCGImageSourceShouldCache: false] as CFDictionary) != nil else {
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

    private func checkRepeatedInput(_ input: InputFingerprint, jpeg: Data,
                                    previousInput: inout InputFingerprint?, previousJPEG: inout Data?,
                                    repeatedInputs: inout Int) throws {
        if previousInput == input && previousJPEG == jpeg {
            repeatedInputs += 1
        } else {
            repeatedInputs = 1
        }
        previousInput = input
        previousJPEG = jpeg
        guard repeatedInputs < 3 else {
            throw PhoneVisionError.unavailable("The same action didn’t change the phone’s screen. Check the connection and screen before trying again.")
        }
    }

    private func description(of action: PhonePromptAction) -> String {
        switch action {
        case .home: "Go Home"
        case .tap(let x, let y): "Tap at \(Int(x * 100))%, \(Int(y * 100))%"
        case .swipe(let direction): "Swipe \(direction.rawValue)"
        case .drag(let x1, let y1, let x2, let y2): "Drag from \(Int(x1 * 100))%, \(Int(y1 * 100))% to \(Int(x2 * 100))%, \(Int(y2 * 100))%"
        case .typeText: "Type text"
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
