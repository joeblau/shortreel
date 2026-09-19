import Foundation

// swiftc -swift-version 6 Engage/Services/DevicePrompts/DevicePromptPlan.swift Engage/Services/DevicePrompts/DevicePromptPlanner.swift Engage/Services/DevicePrompts/PhoneVisionTypes.swift Engage/Services/DevicePrompts/PhoneHomeNavigator.swift Tests/PhoneHomeNavigatorTests.swift -o /tmp/engage-home-navigator-tests
@main @MainActor
enum PhoneHomeNavigatorTests {
    enum Failure: Error { case assertion(String) }
    static let menu: [PhoneHomeTarget] = [
        .init(text: "Home", x: 0.5, y: 0.7),
        .init(text: "Device", x: 0.7, y: 0.5),
        .init(text: "Gestures", x: 0.3, y: 0.5),
    ]

    static func expect(_ value: Bool, _ message: String) throws {
        if !value { throw Failure.assertion(message) }
    }

    static func frame(after: Date, source: String = "phone") -> PhoneScreenFrame {
        .init(id: UUID(), capturedAt: max(Date(), after.addingTimeInterval(0.0001)),
            pixelWidth: 1, pixelHeight: 1, jpegData: Data([1]), sourceID: source)
    }

    static func main() async throws {
        var events: [String] = []
        var lastInput = Date.distantPast
        let navigator = PhoneHomeNavigator(openMenu: {
            events.append("open"); lastInput = Date()
        }, capture: { after in
            try expect(after.timeIntervalSince(lastInput) >= 0.19,
                "The capture barrier preceded the menu/Home animation settling")
            events.append("capture")
            return frame(after: after)
        }, recognize: { _ in events.append("OCR"); return menu }, tap: { x, y in
            try expect(x == 0.5 && y == 0.7, "Home did not use the observed label center")
            events.append("tap"); lastInput = Date()
        }, blockedReason: { nil })
        try await navigator.goHome(sourceID: "phone")
        try expect(events == ["open", "capture", "OCR", "tap", "capture"], "Home skipped observation or result capture")

        let invalidMenus = [
            Array(menu.prefix(1)),
            menu + [.init(text: "Home", x: 0.1, y: 0.1)],
            [.init(text: "Homepage", x: 0.5, y: 0.5)] + Array(menu.dropFirst()),
            [menu[0], menu[1], menu[1]],
            [.init(text: "Home", x: .nan, y: 0.5)] + Array(menu.dropFirst()),
        ]
        for targets in invalidMenus {
            do {
                _ = try PhoneHomeNavigator.homeTarget(in: targets)
                throw Failure.assertion("An ambiguous or unproven menu authorized Home")
            } catch is PhoneVisionError { }
        }

        for scenario in ["blocked", "wrongSource", "stale", "ownershipChanged", "menuMissing"] {
            var blocked = scenario == "blocked"
            var opens = 0
            var taps = 0
            let navigator = PhoneHomeNavigator(openMenu: { opens += 1 }, capture: { after in
                if scenario == "stale" {
                    return .init(id: UUID(), capturedAt: after, pixelWidth: 1, pixelHeight: 1,
                        jpegData: Data([1]), sourceID: "phone")
                }
                return frame(after: after, source: scenario == "wrongSource" ? "another phone" : "phone")
            }, recognize: { _ in
                if scenario == "ownershipChanged" { blocked = true }
                return scenario == "menuMissing" ? [] : menu
            }, tap: { _, _ in taps += 1 }, blockedReason: { blocked ? "Screen ownership lost" : nil })
            do {
                try await navigator.goHome(sourceID: "phone")
                throw Failure.assertion("Invalid navigation completed: \(scenario)")
            } catch is PhoneVisionError { }
            try expect(taps == 0 && opens == (scenario == "blocked" ? 0 : 1),
                "A failed menu check sent a tap or fallback input: \(scenario)")
        }

        var recognitionStarted = false
        var releaseRecognition: CheckedContinuation<Void, Never>?
        var cancelledTaps = 0
        let cancelled = PhoneHomeNavigator(openMenu: {}, capture: { frame(after: $0) }, recognize: { _ in
            recognitionStarted = true
            await withCheckedContinuation { releaseRecognition = $0 }
            return menu
        }, tap: { _, _ in cancelledTaps += 1 }, blockedReason: { nil })
        let task = Task { try await cancelled.goHome(sourceID: "phone") }
        while !recognitionStarted { try await Task.sleep(for: .milliseconds(1)) }
        task.cancel()
        releaseRecognition?.resume()
        do {
            try await task.value
            throw Failure.assertion("Cancelled OCR result authorized Home")
        } catch is CancellationError { }
        try expect(cancelledTaps == 0, "Late OCR sent input after cancellation")
        print("Home navigator tests passed: observed menu, settled fresh frames, exact unique target, source ownership, cancellation, and no fallback")
    }
}
