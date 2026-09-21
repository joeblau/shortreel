import AppKit
import CoreGraphics
import Foundation

// swiftc -swift-version 6 ShortReel/Services/DevicePrompts/{DevicePromptPlan,DevicePromptPlanner,PhoneVisionTypes,PhonePlaybackTracker}.swift Tests/PhonePlaybackTrackerTests.swift -o /tmp/shortreel-playback-tests && /tmp/shortreel-playback-tests
@main
enum PhonePlaybackTrackerTests {
    enum Failure: Error { case assertion(String) }
    static func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw Failure.assertion(message) }
    }
    static func observation(_ timer: String, at seconds: Double, source: String = "SR1",
                            platform: String = "TikTok", caption: String = "A walk through the autumn forest",
                            handle: String = "@nature.camera", confidence: Float = 0.99,
                            timerY: Double = 0.88) -> PhonePlaybackTracker.Observation {
        .init(sourceID: source, capturedAt: Date(timeIntervalSince1970: seconds), platform: platform, regions: [
            .init(text: handle, confidence: 0.99, bounds: CGRect(x: 0.04, y: 0.73, width: 0.5, height: 0.025)),
            .init(text: caption, confidence: 0.99, bounds: CGRect(x: 0.04, y: 0.78, width: 0.75, height: 0.025)),
            .init(text: timer, confidence: confidence, bounds: CGRect(x: 0.04, y: timerY, width: 0.35, height: 0.025))
        ])
    }
    @MainActor static func main() async throws {
        var tracker = PhonePlaybackTracker()
        try check(!tracker.observe(observation("0:07 / 0:10", at: 1)).replayCandidate, "First timer cannot prove completion")
        try check(!tracker.observe(observation("0:09 / 0:10", at: 3)).replayCandidate, "Near-end timer cannot prove completion")
        try check(tracker.observe(observation("0:00 / 0:10", at: 5)).replayCandidate, "Same-player progress reset should flag replay for review")

        // Each boundary must prevent history from one viewing establishing a
        // different viewing's completion.
        let boundaries: [PhonePlaybackTracker.Observation] = [
            observation("0:00/0:10", at: 5, source: "SR2"),
            observation("0:00/0:10", at: 5, platform: "YouTube"),
            observation("0:00/0:10", at: 5, caption: "Another walk along the ocean shore"),
            observation("0:00/0:10", at: 5, handle: "@different.creator"),
            observation("0:00/0:11", at: 5),
            observation("0:00/0:10", at: 3),
            observation("0:00/0:10", at: 40),
            observation("0:00/0:10", at: 5, timerY: 0.82),
        ]
        for boundary in boundaries {
            tracker.reset()
            _ = tracker.observe(observation("0:07/0:10", at: 1))
            _ = tracker.observe(observation("0:09/0:10", at: 3))
            try check(!tracker.observe(boundary).replayCandidate, "Cross-boundary replay evidence was accepted")
        }

        tracker.reset()
        _ = tracker.observe(observation("0:09/0:10", at: 1))
        _ = tracker.observe(observation("0:09/0:10", at: 3))
        try check(!tracker.observe(observation("0:00/0:10", at: 5)).replayCandidate, "Static frames do not establish prior playback")
        tracker.reset()
        _ = tracker.observe(observation("0:01/1:00", at: 1))
        _ = tracker.observe(observation("0:59/1:00", at: 2))
        try check(!tracker.observe(observation("0:00/1:00", at: 3)).replayCandidate, "Seek or OCR jump was counted as ordinary playback")

        for timer in ["9:41", "0:99/1:00", "0:11/0:10", "00:01/00:00", "Watch 0:01/0:10", "0:1/0:10"] {
            tracker.reset()
            let result = tracker.observe(observation(timer, at: 1))
            try check(result.summary.contains("no unique readable"), "Malformed or non-player timer accepted: \(timer)")
        }
        try check(tracker.observe(observation("0:01/0:10", at: 1, confidence: 0.5)).summary.contains("no unique readable"), "Low-confidence OCR accepted")
        try check(tracker.observe(observation("0:01/0:10", at: 1, timerY: 0.1)).summary.contains("no unique readable"), "Status/search region accepted as player timer")

        tracker.reset()
        _ = tracker.observe(observation("0:07/0:10", at: 1, handle: "Generic title"))
        _ = tracker.observe(observation("0:09/0:10", at: 3, handle: "Generic title"))
        try check(!tracker.observe(observation("0:00/0:10", at: 5, handle: "Generic title")).replayCandidate, "Missing explicit creator anchor was accepted")

        tracker.reset()
        _ = tracker.observe(observation("0:07/0:10", at: 1))
        _ = tracker.observe(observation("0:09/0:10", at: 3))
        _ = tracker.observe(.init(sourceID: "SR1", capturedAt: Date(timeIntervalSince1970: 4), platform: "TikTok", regions: []))
        try check(!tracker.observe(observation("0:00/0:10", at: 5)).replayCandidate, "Missing timer must break continuity")

        tracker.reset()
        _ = tracker.observe(observation("0:07/0:10", at: 1))
        _ = tracker.observe(observation("0:09/0:10", at: 3))
        tracker.reset()
        try check(!tracker.observe(observation("0:00/0:10", at: 5)).replayCandidate, "Explicit input/reset must break continuity")

        let original = observation("0:01/0:10", at: 1)
        let duplicate = PhonePlaybackTracker.Observation(sourceID: original.sourceID, capturedAt: original.capturedAt,
            platform: original.platform, regions: original.regions + [original.regions.last!])
        try check(tracker.observe(duplicate).summary.contains("no unique readable"), "Multiple timers could be a results grid and must remain unknown")
        try await actualOCR()
        print("Playback tracker tests passed (replay evidence, continuity boundaries, static/seek rejection, timer validation, reset)")
    }

    @MainActor private static func actualOCR() async throws {
        let context = CGContext(data: nil, width: 480, height: 1040, bitsPerComponent: 8, bytesPerRow: 480 * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 480, height: 1040))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 24, weight: .semibold), .foregroundColor: NSColor.white]
        ("0:09 / 0:10" as NSString).draw(at: CGPoint(x: 24, y: 110), withAttributes: attributes)
        NSGraphicsContext.restoreGraphicsState()
        let frame = PhoneScreenFrame(id: UUID(), capturedAt: Date(), pixelWidth: 480, pixelHeight: 1040,
            jpegData: Data(), cgImage: context.makeImage()!, sourceID: "synthetic")
        var tracker = PhonePlaybackTracker()
        let result = await tracker.observe(frame: frame, platform: "TikTok")
        try check(result.summary.contains("visible timer 0:09/0:10"), "Actual Vision OCR did not recognize the synthetic player timer: \(result.summary)")
        try check(!result.replayCandidate, "Single OCR screenshot must not indicate completion")
    }
}
