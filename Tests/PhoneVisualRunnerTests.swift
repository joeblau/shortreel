import Foundation
import CoreGraphics
import ImageIO

// swiftc -swift-version 6 ShortReel/Services/DevicePrompts/DevicePromptPlan.swift ShortReel/Services/DevicePrompts/DevicePromptPlanner.swift ShortReel/Services/DevicePrompts/PhoneVisionTypes.swift ShortReel/Services/DevicePrompts/PhoneVisualRunner.swift Tests/PhoneVisualRunnerTests.swift -o /tmp/shortreel-visual-runner-tests
@main @MainActor
enum PhoneVisualRunnerTests {
    private enum TestError: LocalizedError {
        case failed(String)
        var errorDescription: String? {
            switch self { case .failed(let message): message }
        }
    }

    @MainActor private final class Gate {
        private(set) var waiting = false
        private var continuation: CheckedContinuation<Void, Never>?

        func wait() async {
            waiting = true
            await withCheckedContinuation { continuation = $0 }
        }

        func release() {
            continuation?.resume()
            continuation = nil
        }
    }

    static func main() async throws {
        try await observationOrderAndVerification()
        try await rejectUnfreshFrames()
        try await rejectChangedSourceAndDuplicateID()
        try await rejectMalformedImages()
        try await stopRepeatedInput()
        try await rejectMalformedDecisions()
        try await requireClarification()
        try await disconnectBeforeDispatch()
        try await cancelledModelCannotDispatch()
        try await cancellationStopsRemainingInput()
        try await decisionAndDurationLimits()
        try await failedInputStopsLoop()
        print("Phone visual runner tests passed (12 scenarios)")
    }

    private static func observationOrderAndVerification() async throws {
        var events: [String] = []
        var frames: [PhoneScreenFrame] = []
        var steps: [PhoneVisionStep] = []
        var completedAt: Date?
        var decisionCount = 0
        let runner = PhoneVisualRunner(capture: { after in
            if let completedAt { try expect(after >= completedAt, "Capture requested a frame from before input completion") }
            events.append("capture")
            let next = try frame(after: after, shade: Double(frames.count) / 4)
            frames.append(next)
            return next
        }, decide: { goal, frame, history in
            try expect(goal == "Open settings", "The goal changed between decisions")
            try expect(frame == frames.last, "The model received the wrong frame")
            try expect(history == steps, "The model did not receive the completed step history")
            events.append("decide")
            decisionCount += 1
            switch decisionCount {
            case 1: return .action(.home, reason: "Show the Home screen.")
            case 2: return .action(.tap(0.25, 0.75), reason: "Settings is visible here.")
            default:
                try expect(frames.count == 3, "Finished without a post-action screen")
                return .finished("Settings is open on the phone.")
            }
        }, perform: { action in
            events.append("perform")
            try expect(action == .home || action == .tap(0.25, 0.75), "Unexpected input")
            completedAt = Date()
        }, blockedReason: { nil })
        let result = try await runner.run(goal: "Open settings", onProgress: { _ in }, onStep: { steps.append($0) })
        try expect(result == "Settings is open on the phone.", "The final screen result was lost")
        try expect(events == ["capture", "decide", "perform", "capture", "decide", "perform", "capture", "decide"], "Input ran without observing a fresh screen")
        try expect(steps.count == 2 && steps.map(\.number) == [1, 2], "Step log is incomplete")
        try expect(steps[0].capturedAt == frames[0].capturedAt && steps[1].capturedAt == frames[1].capturedAt, "Step logs lost source-frame timestamps")
        try expect(steps[1].detail == "Settings is visible here.", "The model's action reason was lost")
    }

    private static func rejectUnfreshFrames() async throws {
        for offset in [-121.0, -0.01, 0.0, 600.0] {
            var decisions = 0
            var inputs = 0
            let runner = PhoneVisualRunner(capture: { after in
                let valid = try frame(after: after)
                return copy(valid, capturedAt: after.addingTimeInterval(offset))
            }, decide: { _, _, _ in
                decisions += 1
                return .finished("Done")
            }, perform: { _ in inputs += 1 }, blockedReason: { nil })
            try await expectFailure(.stale) { try await runner.run(goal: "Open settings", onProgress: { _ in }, onStep: { _ in }) }
            try expect(decisions == 0 && inputs == 0, "A stale/future frame reached the model or driver")
        }
    }

    private static func rejectChangedSourceAndDuplicateID() async throws {
        for changeSource in [true, false] {
            let firstID = UUID()
            var captures = 0
            var decisions = 0
            var inputs = 0
            let runner = PhoneVisualRunner(capture: { after in
                captures += 1
                return try frame(after: after, id: changeSource ? UUID() : firstID,
                    source: changeSource && captures > 1 ? "Other Phone" : "Phone")
            }, decide: { _, _, _ in
                decisions += 1
                return .action(.home, reason: "Show the Home screen.")
            }, perform: { _ in inputs += 1 }, blockedReason: { nil })
            try await expectFailure(changeSource ? .source : .stale) {
                try await runner.run(goal: "Open settings", onProgress: { _ in }, onStep: { _ in })
            }
            try expect(inputs == 1 && decisions == 1 && captures == 2, "An invalid second frame was used for another input")
        }
    }

    private static func rejectMalformedImages() async throws {
        for invalidCase in 0..<6 {
            var decisions = 0
            let runner = PhoneVisualRunner(capture: { after in
                let good = try frame(after: after)
                switch invalidCase {
                case 0: return copy(good, data: Data())
                case 1: return copy(good, data: Data([0xFF, 0xD8, 0x01, 0x02, 0xFF, 0xD9]))
                case 2: return copy(good, width: 0)
                case 3: return copy(good, width: 999_999)
                case 4: return copy(good, width: good.pixelWidth + 1)
                default: return copy(good, source: "  ")
                }
            }, decide: { _, _, _ in
                decisions += 1
                return .finished("Done")
            }, perform: { _ in throw TestError.failed("Malformed image reached input driver") }, blockedReason: { nil })
            try await expectFailure(.unavailable) { try await runner.run(goal: "Open settings", onProgress: { _ in }, onStep: { _ in }) }
            try expect(decisions == 0, "Malformed image reached the model")
        }
    }

    private static func stopRepeatedInput() async throws {
        for waiting in [false, true] {
            var decisions = 0
            var inputs = 0
            var steps = 0
            let runner = PhoneVisualRunner(capture: { try frame(after: $0) }, decide: { _, _, _ in
                decisions += 1
                // Different wording must not bypass the repeated input guard.
                return waiting ? .wait(seconds: 0.25, reason: "Wait \(decisions)") : .action(.tap(0.5, 0.5), reason: "Tap \(decisions)")
            }, perform: { _ in inputs += 1 }, blockedReason: { nil })
            try await expectFailure(.unavailable) {
                try await runner.run(goal: "Open settings", onProgress: { _ in }, onStep: { _ in steps += 1 })
            }
            try expect(decisions == 3 && steps == 2, "Repeated unchanged screens did not stop at the third decision")
            try expect(inputs == (waiting ? 0 : 2), "The third blind input was dispatched")
        }
        // Identical actions remain allowed when their input screen has changed.
        var decisions = 0
        var inputs = 0
        let changing = PhoneVisualRunner(capture: { try frame(after: $0, shade: Double(decisions) / 5) }, decide: { _, _, _ in
            decisions += 1
            return decisions <= 3 ? .action(.swipe(.up), reason: "More content is below.") : .finished("The item is visible.")
        }, perform: { _ in inputs += 1 }, blockedReason: { nil })
        _ = try await changing.run(goal: "Find the item", onProgress: { _ in }, onStep: { _ in })
        try expect(inputs == 3, "Changing screens were incorrectly treated as a blind loop")
    }

    private static func rejectMalformedDecisions() async throws {
        let badDecisions: [PhoneVisionDecision] = [
            .action(.tap(.nan, 0), reason: "Tap"),
            .action(.drag(0, 0, 2, 0), reason: "Drag"),
            .action(.openApp("Settings"), reason: "Open Settings"),
            .action(.search("Settings"), reason: "Search"),
            .action(.typeText(String(repeating: "a", count: 101)), reason: "Type"),
            .action(.home, reason: ""), .action(.typeText("😀"), reason: "Type"),
            .wait(seconds: .infinity, reason: "Wait"), .wait(seconds: 4, reason: "Wait"),
            .finished(""), .needsInput(""),
        ]
        for decision in badDecisions {
            var inputs = 0
            let runner = PhoneVisualRunner(capture: { try frame(after: $0) }, decide: { _, _, _ in decision },
                perform: { _ in inputs += 1 }, blockedReason: { nil })
            try await expectFailure(.invalid) { try await runner.run(goal: "Open settings", onProgress: { _ in }, onStep: { _ in }) }
            try expect(inputs == 0, "Malformed decision sent input")
        }
    }

    private static func requireClarification() async throws {
        let runner = PhoneVisualRunner(capture: { try frame(after: $0) }, decide: { _, _, _ in
            .needsInput("Which account should I choose?")
        }, perform: { _ in throw TestError.failed("Clarification dispatched input") }, blockedReason: { nil })
        do {
            _ = try await runner.run(goal: "Choose my account", onProgress: { _ in }, onStep: { _ in })
            throw TestError.failed("Clarification was reported as success")
        } catch let error as PhonePromptPlanningError {
            try expect(error.localizedDescription == "Which account should I choose?", "Clarification message was lost")
        }
    }

    private static func disconnectBeforeDispatch() async throws {
        for disconnectInStep in [true, false] {
            var connected = true
            var inputs = 0
            let runner = PhoneVisualRunner(capture: { try frame(after: $0) }, decide: { _, _, _ in
                if !disconnectInStep { connected = false }
                return .action(.home, reason: "Show the Home screen.")
            }, perform: { _ in inputs += 1 }, blockedReason: { connected ? nil : "Phone disconnected" })
            try await expectFailure(.unavailable) {
                try await runner.run(goal: "Open settings", onProgress: { _ in }, onStep: { _ in connected = false })
            }
            try expect(inputs == 0, "A disconnected phone received input")
        }
    }

    private static func cancelledModelCannotDispatch() async throws {
        let gate = Gate()
        var inputs = 0
        let runner = PhoneVisualRunner(capture: { try frame(after: $0) }, decide: { _, _, _ in
            await gate.wait() // Deliberately ignores cancellation until released.
            return .action(.home, reason: "Show the Home screen.")
        }, perform: { _ in inputs += 1 }, blockedReason: { nil })
        let task = Task { try await runner.run(goal: "Open settings", onProgress: { _ in }, onStep: { _ in }) }
        try await waitUntil { gate.waiting }
        task.cancel()
        do {
            _ = try await task.value
            throw TestError.failed("Cancelled model run returned success")
        } catch is CancellationError { }
        gate.release()
        await Task.yield()
        try expect(inputs == 0, "A late cancelled model result dispatched input")
    }

    private static func cancellationStopsRemainingInput() async throws {
        let gate = Gate()
        var inputs = 0
        var captures = 0
        let runner = PhoneVisualRunner(capture: {
            captures += 1
            return try frame(after: $0)
        }, decide: { _, _, _ in .action(.home, reason: "Show the Home screen.") }, perform: { _ in
            inputs += 1
            await gate.wait()
        }, blockedReason: { nil })
        let task = Task { try await runner.run(goal: "Open settings", onProgress: { _ in }, onStep: { _ in }) }
        try await waitUntil { gate.waiting }
        task.cancel()
        do {
            _ = try await task.value
            throw TestError.failed("Cancelled input run returned success")
        } catch is CancellationError { }
        gate.release()
        await Task.yield()
        try expect(inputs == 1 && captures == 1, "Cancelled input continued to another screen/action")
    }

    private static func decisionAndDurationLimits() async throws {
        var decisions = 0
        var inputs = 0
        let bounded = PhoneVisualRunner(capture: { try frame(after: $0, shade: Double(decisions) / 5) }, decide: { _, _, _ in
            decisions += 1
            return .action(.home, reason: "Show the Home screen.")
        }, perform: { _ in inputs += 1 }, blockedReason: { nil }, maximumSteps: 2)
        try await expectFailure(.limit) { try await bounded.run(goal: "Open settings", onProgress: { _ in }, onStep: { _ in }) }
        try expect(decisions == 2 && inputs == 2, "The decision limit was exceeded")

        let gate = Gate()
        var lateInputs = 0
        let timed = PhoneVisualRunner(capture: { try frame(after: $0) }, decide: { _, _, _ in
            await gate.wait()
            return .action(.home, reason: "Show the Home screen.")
        }, perform: { _ in lateInputs += 1 }, blockedReason: { nil }, maximumDuration: 0.05)
        try await expectFailure(.limit) { try await timed.run(goal: "Open settings", onProgress: { _ in }, onStep: { _ in }) }
        try expect(gate.waiting, "Timed test never entered the pending model")
        gate.release()
        await Task.yield()
        try expect(lateInputs == 0, "An expired model result dispatched input")
    }

    private static func failedInputStopsLoop() async throws {
        var captures = 0
        var inputs = 0
        let runner = PhoneVisualRunner(capture: {
            captures += 1
            return try frame(after: $0)
        }, decide: { _, _, _ in .action(.home, reason: "Show the Home screen.") }, perform: { _ in
            inputs += 1
            throw PhoneVisionError.unavailable("Bluetooth write failed")
        }, blockedReason: { nil })
        try await expectFailure(.unavailable) { try await runner.run(goal: "Open settings", onProgress: { _ in }, onStep: { _ in }) }
        try expect(captures == 1 && inputs == 1, "The loop continued after failed input")
    }

    private static func frame(after: Date, id: UUID = UUID(), source: String = "Phone", shade: Double = 0) throws -> PhoneScreenFrame {
        let width = 8
        let height = 12
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: colorSpace, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
            throw TestError.failed("Could not create image fixture")
        }
        context.setFillColor(red: shade, green: shade, blue: shade, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        guard let image = context.makeImage() else { throw TestError.failed("Could not create image fixture") }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil) else {
            throw TestError.failed("Could not create JPEG fixture")
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw TestError.failed("Could not encode JPEG fixture") }
        let timestamp = max(Date(), after.addingTimeInterval(0.000_001))
        return .init(id: id, capturedAt: timestamp, pixelWidth: width, pixelHeight: height, jpegData: data as Data, cgImage: image, sourceID: source)
    }

    private static func copy(_ frame: PhoneScreenFrame, capturedAt: Date? = nil, data: Data? = nil, width: Int? = nil, source: String? = nil) -> PhoneScreenFrame {
        .init(id: frame.id, capturedAt: capturedAt ?? frame.capturedAt, pixelWidth: width ?? frame.pixelWidth,
            pixelHeight: frame.pixelHeight, jpegData: data ?? frame.jpegData, cgImage: frame.cgImage, sourceID: source ?? frame.sourceID)
    }

    private enum ExpectedError { case stale, source, unavailable, invalid, limit }

    private static func expectFailure(_ expected: ExpectedError, operation: () async throws -> String) async throws {
        do {
            _ = try await operation()
            throw TestError.failed("Expected visual request to fail: \(expected)")
        } catch let error as PhoneVisionError {
            let matches: Bool = switch (expected, error) {
            case (.stale, .staleFrame), (.source, .sourceChanged), (.unavailable, .unavailable),
                 (.invalid, .invalidDecision), (.limit, .limitReached): true
            default: false
            }
            try expect(matches, "Unexpected visual failure: \(error)")
        } catch is PhonePromptPlanningError {
            try expect(expected == .invalid, "Unexpected planning failure")
        }
    }

    private static func waitUntil(_ predicate: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(2)
        while !predicate() {
            guard ContinuousClock.now < deadline else { throw TestError.failed("Timed out waiting for test state") }
            try await Task.sleep(for: .milliseconds(1))
        }
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw TestError.failed(message) }
    }
}
