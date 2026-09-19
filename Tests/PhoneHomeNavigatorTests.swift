import CoreGraphics
import Foundation

// swiftc -swift-version 6 ShortReel/Services/DevicePrompts/DevicePromptPlan.swift ShortReel/Services/DevicePrompts/DevicePromptPlanner.swift ShortReel/Services/DevicePrompts/PhoneVisionTypes.swift ShortReel/Services/DevicePrompts/PhoneHomeNavigator.swift Tests/PhoneHomeNavigatorTests.swift -o /tmp/shortreel-home-navigator-tests
@main @MainActor
enum PhoneHomeNavigatorTests {
    enum Failure: Error { case assertion(String), driver }

    static func expect(_ value: Bool, _ message: String) throws {
        if !value { throw Failure.assertion(message) }
    }

    static func frame(after: Date, source: String = "phone", id: UUID = UUID()) -> PhoneScreenFrame {
        let image = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8,
            bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!.makeImage()!
        return .init(id: id, capturedAt: max(Date(), after.addingTimeInterval(0.0001)),
            pixelWidth: 1, pixelHeight: 1, jpegData: Data([1]), cgImage: image, sourceID: source)
    }

    static func main() async throws {
        var events: [String] = []
        var lastInput: Date?
        let navigator = PhoneHomeNavigator(swipeHome: {
            events.append("swipe"); lastInput = Date()
        }, capture: { after in
            if let lastInput {
                try expect(after.timeIntervalSince(lastInput) >= 0.34,
                    "Result capture preceded the Home animation settling")
            }
            events.append("capture")
            return frame(after: after)
        }, blockedReason: { nil })
        try await navigator.goHome(sourceID: "phone")
        try expect(events == ["capture", "swipe", "capture"], "Home skipped a frame or repeated the swipe")

        for scenario in ["blocked", "wrongSource", "stale", "ownershipChanged",
                         "resultWrongSource", "resultStale", "duplicateFrame", "lostAfterSwipe"] {
            var blocked = scenario == "blocked"
            var captures = 0
            var swipes = 0
            let duplicateID = UUID()
            let navigator = PhoneHomeNavigator(swipeHome: {
                swipes += 1
                if scenario == "lostAfterSwipe" { blocked = true }
            }, capture: { after in
                captures += 1
                if scenario == "ownershipChanged" { blocked = true }
                if (scenario == "stale" && captures == 1) || (scenario == "resultStale" && captures == 2) {
                    return frame(after: after).captured(at: after)
                }
                let wrongSource = (scenario == "wrongSource" && captures == 1)
                    || (scenario == "resultWrongSource" && captures == 2)
                return frame(after: after, source: wrongSource ? "another phone" : "phone",
                    id: scenario == "duplicateFrame" ? duplicateID : UUID())
            }, blockedReason: { blocked ? "Screen ownership lost" : nil })
            do {
                try await navigator.goHome(sourceID: "phone")
                throw Failure.assertion("Invalid navigation completed: \(scenario)")
            } catch is PhoneVisionError { }
            let failsBeforeSwipe = ["blocked", "wrongSource", "stale", "ownershipChanged"].contains(scenario)
            try expect(swipes == (failsBeforeSwipe ? 0 : 1), "Unexpected input after failure: \(scenario)")
        }

        var captures = 0
        let failingDriver = PhoneHomeNavigator(swipeHome: { throw Failure.driver }, capture: {
            captures += 1
            return frame(after: $0)
        }, blockedReason: { nil })
        do {
            try await failingDriver.goHome(sourceID: "phone")
            throw Failure.assertion("Driver failure was ignored")
        } catch Failure.driver { }
        try expect(captures == 1, "Failed swipe continued to result capture")

        var captureStarted = false
        var releaseCapture: CheckedContinuation<Void, Never>?
        var cancelledSwipes = 0
        let cancelled = PhoneHomeNavigator(swipeHome: { cancelledSwipes += 1 }, capture: { after in
            captureStarted = true
            await withCheckedContinuation { releaseCapture = $0 }
            return frame(after: after)
        }, blockedReason: { nil })
        let task = Task { try await cancelled.goHome(sourceID: "phone") }
        while !captureStarted { try await Task.sleep(for: .milliseconds(1)) }
        task.cancel()
        releaseCapture?.resume()
        do {
            try await task.value
            throw Failure.assertion("Cancelled capture authorized Home")
        } catch is CancellationError { }
        try expect(cancelledSwipes == 0, "Late capture sent input after cancellation")

        var cancelledCaptures = 0
        let cancelDuringSwipe = PhoneHomeNavigator(swipeHome: {
            withUnsafeCurrentTask { $0?.cancel() }
        }, capture: {
            cancelledCaptures += 1
            return frame(after: $0)
        }, blockedReason: { nil })
        let swipeTask = Task { try await cancelDuringSwipe.goHome(sourceID: "phone") }
        do {
            try await swipeTask.value
            throw Failure.assertion("Cancellation during swipe was ignored")
        } catch is CancellationError { }
        try expect(cancelledCaptures == 1, "Cancelled swipe continued to result capture")
        print("Home navigator tests passed: swipe, fresh frames, source ownership, driver failure, and cancellation")
    }
}

private extension PhoneScreenFrame {
    func captured(at date: Date) -> Self {
        .init(id: id, capturedAt: date, pixelWidth: pixelWidth, pixelHeight: pixelHeight,
            jpegData: jpegData, cgImage: cgImage, sourceID: sourceID)
    }
}
