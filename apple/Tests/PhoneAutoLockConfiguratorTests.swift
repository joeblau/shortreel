import CoreGraphics
import Foundation

// swiftc -swift-version 6 ShortReel/Services/DevicePrompts/DevicePromptPlan.swift ShortReel/Services/DevicePrompts/DevicePromptPlanner.swift ShortReel/Services/DevicePrompts/PhoneVisionTypes.swift ShortReel/Services/DevicePrompts/PhoneAutoLockConfigurator.swift Tests/PhoneAutoLockConfiguratorTests.swift -o /tmp/shortreel-autolock-tests
@main @MainActor
enum PhoneAutoLockConfiguratorTests {
    enum Failure: Error { case assertion(String) }
    static let page: [PhoneHomeTarget] = [
        .init(text: "Auto-Lock", x: 0.5, y: 0.1),
        .init(text: "30 Seconds", x: 0.2, y: 0.3),
        .init(text: "1 Minute", x: 0.2, y: 0.38),
        .init(text: "5 Minutes", x: 0.2, y: 0.62),
        .init(text: "Never", x: 0.2, y: 0.7),
    ]

    static func expect(_ value: Bool, _ message: String) throws {
        if !value { throw Failure.assertion(message) }
    }

    static func frame(after: Date, source: String = "phone") -> PhoneScreenFrame {
        let image = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8,
            bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!.makeImage()!
        return .init(id: UUID(), capturedAt: max(Date(), after.addingTimeInterval(0.0001)),
            pixelWidth: 1, pixelHeight: 1, jpegData: Data([1]), cgImage: image, sourceID: source)
    }

    static func main() async throws {
        // The full run types the search, opens the page, and taps Never.
        var events: [String] = []
        let configurator = PhoneAutoLockConfigurator(openSearch: {
            events.append("search")
        }, type: { text in
            events.append("type:\(text)")
        }, confirm: {
            events.append("confirm")
        }, capture: { after in
            events.append("capture")
            return frame(after: after)
        }, recognize: { _ in
            page
        }, tap: { x, y in
            events.append("tap:\(x),\(y)")
        }, blockedReason: { nil })
        try await configurator.disableAutoLock(sourceID: "phone")
        try expect(events == ["search", "type:Auto-Lock", "confirm", "capture", "tap:0.2,0.7", "capture"],
            "Unexpected sequence \(events)")

        // The target picker requires the page shape, not just any "Never" text.
        let target = try PhoneAutoLockConfigurator.neverTarget(in: page)
        try expect(target.x == 0.2 && target.y == 0.7, "Never row not selected")
        for targets in [
            [PhoneHomeTarget(text: "Never", x: 0.2, y: 0.7)],
            page + [PhoneHomeTarget(text: "Never", x: 0.4, y: 0.8)],
            page.filter { $0.text != "Never" },
            [PhoneHomeTarget(text: "Never", x: 1.2, y: 0.7)] + page,
        ] {
            do {
                _ = try PhoneAutoLockConfigurator.neverTarget(in: targets)
                throw Failure.assertion("Accepted ambiguous targets \(targets.map(\.text))")
            } catch is PhoneVisionError {}
        }

        // A stopped run performs no input.
        do {
            let blocked = PhoneAutoLockConfigurator(openSearch: { throw Failure.assertion("input while blocked") },
                type: { _ in }, confirm: {}, capture: { _ in throw Failure.assertion("capture while blocked") },
                recognize: { _ in [] }, tap: { _, _ in }, blockedReason: { "blocked" })
            try await blocked.disableAutoLock(sourceID: "phone")
            throw Failure.assertion("A blocked run did not stop")
        } catch PhoneVisionError.unavailable {}

        print("Phone auto-lock configurator tests passed")
    }
}
