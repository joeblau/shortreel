import Foundation
import CoreGraphics

// From apple/: swiftc -swift-version 6 ShortReel/Services/DevicePrompts/{WarmUpScript,WarmUpStateTree,PhonePlaybackTracker,DevicePromptPlan,DevicePromptPlanner,PhoneVisionTypes}.swift Tests/WarmUpStateTreeTests.swift -o /tmp/shortreel-state-tests && /tmp/shortreel-state-tests
@main
enum WarmUpStateTreeTests {
    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        precondition(condition(), message)
    }
    static func region(_ text: String, _ x: Double, _ y: Double, width: Double = 0.1,
                       confidence: Float = 1) -> PhonePlaybackTracker.TextRegion {
        .init(text: text, confidence: confidence, bounds: CGRect(x: x, y: y, width: width, height: 0.02))
    }
    static let navigation = [region("Home", 0.05, 0.94), region("Inbox", 0.65, 0.94), region("Profile", 0.85, 0.94)]
    static let player = [region("Search", 0.8, 0.08), region("Add comment...", 0.1, 0.93),
                         region("@creator", 0.05, 0.79), region("A caption for this video", 0.05, 0.83),
                         region("64.3K", 0.9, 0.5), region("783", 0.9, 0.6), region("1463", 0.9, 0.7)]
    static func page(_ regions: [PhonePlaybackTracker.TextRegion], platform: String = "TikTok") -> WarmUpPage {
        WarmUpPage.detect(.init(sourceID: "phone", capturedAt: Date(), platform: platform, regions: regions))
    }
    static func cursor(_ step: WarmUpScript.Step.ID) throws -> WarmUpScriptCursor {
        var cursor = WarmUpScriptCursor(script: .init(network: .tikTok, activity: .watch, itemLimit: 2, duration: 300))
        while cursor.step.id != step { try cursor.finishStep() }
        return cursor
    }
    static func main() throws {
        let feed = page(navigation + [region("For You", 0.5, 0.07), region("Following", 0.25, 0.07)])
        expect(feed.kind == .feed, "Feed anchors not recognized")
        let profile = page(navigation + [region("@test.persona", 0.3, 0.2), region("Edit profile", 0.2, 0.4),
                                         region("Following", 0.2, 0.3), region("Followers", 0.4, 0.3)])
        expect(profile.kind == .ownProfile, "Own profile not recognized")
        expect(page(player).kind == .videoPlayer, "Player not recognized")
        expect(page(player, platform: "YouTube").kind == .unknown, "Platform profiles were mixed")
        expect(page([region("Search", 0.8, 0.08), region("Top", 0.1, 0.16),
                     region("Videos", 0.3, 0.16), region("Users", 0.6, 0.16)]).kind == .searchResults,
               "Results tabs not recognized")
        expect(page([region("Search", 0.8, 0.08), region("swing trading", 0.2, 0.08, width: 0.4)]
                    + (0...2).map { region("swing trading topic \($0)", 0.15, 0.2 + Double($0) * 0.1) }).kind == .searchSuggestions,
               "Suggestions not recognized")
        expect(page(player + [region("233 comments", 0.3, 0.4)]).kind == .overlay, "Comments overlay mistaken for player")
        expect(page(player + [region("Allow", 0.3, 0.5), region("Don't Allow", 0.3, 0.6)]).kind == .overlay,
               "Dialog did not take precedence over underlying player")
        expect(page(player.map { .init(text: $0.text, confidence: 0.5, bounds: $0.bounds) }).kind == .unknown,
               "Low-confidence OCR authorized a route")
        expect(page([region("For You", 0.2, 0.1)]).kind == .unknown, "One content label classified a page")
        let brief = "Account check: Open Profile. Verify exactly @test.persona, ignoring case."
        var tree = WarmUpStateTree()
        let account = try cursor(.account)
        let route = tree.route(cursor: account, page: feed, playback: nil, brief: brief)
        if case .action(.tap(let x, let y), _) = route.decision {
            expect(abs(x - 0.9) < 0.001 && abs(y - 0.95) < 0.001, "Tap did not use observed control")
        } else { preconditionFailure("Expected direct profile navigation") }
        _ = tree.route(cursor: account, page: feed, playback: nil, brief: brief)
        expect(tree.route(cursor: account, page: feed, playback: nil, brief: brief).decision == nil,
               "Repeated navigation did not fall back")
        if case .finished = tree.route(cursor: account, page: profile, playback: nil, brief: brief).decision {} else {
            preconditionFailure("Exact own handle did not verify account")
        }
        if case .needsInput = tree.route(cursor: account, page: profile, playback: nil,
                                         brief: brief.replacingOccurrences(of: "test.persona", with: "wrong")).decision {} else {
            preconditionFailure("Mismatched account was accepted")
        }
        expect(tree.route(cursor: account, page: page(player), playback: nil, brief: brief).decision == nil,
               "Player creator was mistaken for signed-in user")
        expect(tree.route(cursor: account, page: profile, playback: nil, brief: "missing").decision == nil,
               "Missing expected handle bypassed account check")
        let consume = try cursor(.consume)
        expect(tree.route(cursor: consume, page: .init(kind: .unknown),
            playback: .init(summary: "timer", replayCandidate: false, durationSeconds: 180), brief: brief).decision == nil,
            "A timer outside a recognized player authorized a skip")
        let moving = PhonePlaybackEvidence(summary: "timer", replayCandidate: false, durationSeconds: 45, isAdvancing: true)
        for _ in 0..<2 {
            if case .wait = tree.route(cursor: consume, page: page(player), playback: moving, brief: brief).decision {} else {
                preconditionFailure("Advancing playback did not short-circuit a wait")
            }
        }
        expect(tree.route(cursor: consume, page: page(player), playback: moving, brief: brief).decision == nil,
               "Local playback waits did not yield to model review")
        for seconds in [59, 60] {
            expect(tree.route(cursor: consume, page: page(player), playback: .init(summary: "timer", replayCandidate: false,
                        durationSeconds: seconds), brief: brief).decision == nil, "Short video skipped")
        }
        if case .action(.swipe(.up), _) = tree.route(cursor: consume, page: page(player),
            playback: .init(summary: "timer", replayCandidate: false, durationSeconds: 61), brief: brief).decision {} else {
            preconditionFailure("Overlong video did not take direct skip route")
        }
        var advance = try cursor(.advance)
        if case .action(.swipe(.up), _) = tree.route(cursor: advance, page: page(player), playback: nil, brief: brief).decision {} else {
            preconditionFailure("Verified completion did not advance directly")
        }
        advance.didPerform(.swipe(.up))
        expect(tree.route(cursor: advance, page: page(player), playback: nil, brief: brief).decision == nil,
               "Second swipe sent before next-video verification")
        let signIn = page([region("Log in to TikTok", 0.2, 0.3), region("Use phone / email / username", 0.2, 0.5)])
        if case .needsInput = tree.route(cursor: consume, page: signIn, playback: nil, brief: brief).decision {} else {
            preconditionFailure("Sign-in did not stop the flow")
        }
        print("Warm-up state tree tests passed (page recognition, navigation, account gate, duration, advance, fallback)")
    }
}
