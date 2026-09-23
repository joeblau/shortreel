import Foundation

@main @MainActor enum PhoneWatchFlowTests {
    typealias T = TransactionTestSupport
    struct Screen {
        let id: String
        let evidence: String
        let selected: String?
        var state: PhoneScreenObservation.State = .foregroundApp
        var progress: Double? = nil
        var item = 1
        var reused = false
    }
    static func main() async throws {
        let script = WarmUpScript(network: .tikTok, activity: .watch, itemLimit: 2, duration: 600)
        let plan = try PhoneTransactionCompiler.tikTokWatch(script: script, query: "swing trading",
            template: Data(contentsOf: URL(fileURLWithPath: "Contracts/tiktok-watch.json")))
        let store = try WarmUpContractStore(data: Data(contentsOf: URL(fileURLWithPath: "Contracts/warmup-tasks.json")))
        let home = "The iPhone Home Screen is visible, with TikTok in the Dock."
        let feed = "TikTok’s interface is visible with the For You tab selected."
        let profile = "TikTok profile page with username and followers."
        let feedWithSearch = "TikTok video feed with For You selected and a Search button."
        let empty = "The TikTok search page shows an empty focused search field with the keyboard visible."
        let suggestions = "The search field contains swing trading and search suggestions are listed below it."
        let top = "Search results for the selected suggestion with the Top tab selected."
        let grid = "A grid of video search results with the Videos tab selected."
        let player = "A full-screen video player with a heart button."
        let playing = "A video is playing with playback controls."
        let screens: [Screen] = [
            .init(id: "account.start", evidence: home, selected: "home", state: .home),
            .init(id: "account.launcher", evidence: "The TikTok app icon is visible in the Dock.", selected: "present", state: .home),
            .init(id: "account.launcher.verify", evidence: feed, selected: "confirmed"),
            .init(id: "account.profile", evidence: feed, selected: "profile", reused: true),
            .init(id: "account.profile.verify", evidence: profile, selected: "confirmed"),
            .init(id: "search.home", evidence: "The signed-in account's profile page is shown with bottom navigation and Profile selected.", selected: "profile"),
            .init(id: "search.home.verify", evidence: feedWithSearch, selected: "confirmed"),
            .init(id: "search.feed", evidence: feedWithSearch, selected: "feed", reused: true),
            .init(id: "search.feed.verify", evidence: empty, selected: "confirmed"),
            .init(id: "search.field", evidence: empty, selected: "empty", reused: true),
            .init(id: "search.field.verify", evidence: suggestions, selected: "confirmed"),
            .init(id: "suggestion.suggestions", evidence: suggestions, selected: "suggestions", reused: true),
            .init(id: "suggestion.suggestions.verify", evidence: top, selected: "confirmed"),
            .init(id: "suggestion.results", evidence: top, selected: "top", reused: true),
            .init(id: "suggestion.results.verify", evidence: grid, selected: "confirmed"),
            .init(id: "open.grid0", evidence: grid, selected: "results", reused: true),
            .init(id: "open.grid0.verify", evidence: "A full-screen video player is visible.", selected: "confirmed"),
            .init(id: "open.player0", evidence: player, selected: "player"),
            .init(id: "consume.playback", evidence: playing, selected: "playing", progress: 0.6),
            .init(id: "consume.playback.verify", evidence: playing, selected: "playing", progress: 0.95),
            .init(id: "consume.playback", evidence: playing, selected: "playing", progress: 0.01),
            .init(id: "advance.player", evidence: "A full-screen video player.", selected: "player", progress: 0.1),
            .init(id: "advance.player.verify", evidence: "A full-screen video player.", selected: "player", progress: 0.1, item: 2),
            .init(id: "consume.playback", evidence: playing, selected: "playing", progress: 0.6, item: 2),
            .init(id: "consume.playback.verify", evidence: playing, selected: "playing", progress: 0.95, item: 2),
            .init(id: "consume.playback", evidence: playing, selected: "playing", progress: 0.01, item: 2)
        ]
        let rig = T.Rig(); rig.plan = plan
        rig.locate = { _, _, _ in .action(.tap(Double(rig.locatorCalls % 8 + 1) / 10, 0.5), reason: "Located the declared control") }
        rig.budgetOverride = { store.step(scriptIdentifier: $0.identifier, stepID: $1.rawValue)?.budget }
        var fixtures: [[String: Any]] = []
        let captured = screens.filter { !$0.reused }
        var asked = 0
        func nextScreen() -> Screen {
            defer { asked += 1 }
            return screens[min(asked, screens.count - 1)]
        }
        rig.observeOverride = { _, _ in
            guard rig.captures <= captured.count else { throw T.Failure.assertion("Workflow took an unexpected extra observation") }
            let screen = captured[rig.captures - 1]
            return .init(state: screen.state, appCardsVisible: false,
                evidence: screen.evidence + (screen.id == "open.player0" ? " Heart count: 25.4K" : ""), checkEvidence: screen.evidence,
                video: screen.progress.map { .init(creator: "@creator\(screen.item)", caption: "A swing trading setup number \(screen.item)", progress: $0, durationSeconds: 10, playing: true) })
        }
        rig.readTextOverride = { frame, platform in
            .init(sourceID: frame.sourceID, capturedAt: frame.capturedAt, platform: platform,
                regions: [.init(text: "swing trading", confidence: 1, bounds: .init(x: 0.1, y: 0.1, width: 0.5, height: 0.03))])
        }
        rig.classifyOverride = { question in
            let screen = nextScreen()
            try T.expect(question.id == screen.id, "Expected \(screen.id), received \(question.id)")
            let expected = screen.selected!
            fixtures.append(["id": question.id, "state": question.evidence, "question": question.question,
                "options": question.options.map { ["id": $0.id, "description": $0.description] }, "expected": expected])
            return expected
        }
        let result = try await rig.run(workflow: .warmUp, script: script)
        try T.expect(result.contains("Verified 2 item(s)"), "Did not watch two items")
        try T.expect(rig.actions.filter { $0 == .swipe(.up) }.count == 1, "Expected exactly one swipe between two completed views")
        try T.expect(rig.actions.contains(.typeText("swing trading")), "Did not type the niche query")
        try T.expect(rig.accountCalls == 1, "Account was not verified exactly once")
        try T.expect(rig.captures == captured.count, "Verified frames were not reused by the next state")
        try T.expect(rig.accountObservations.first?.checkEvidence == profile,
            "The verified profile's visual evidence did not reach the account check")
        let homeOptions = fixtures.first { $0["id"] as? String == "search.home" }?["options"] as? [[String: String]]
        try T.expect(homeOptions?.contains { $0["id"] == "login" } == false,
            "Offered the login stop without visible sign-in controls")
        if let path = ProcessInfo.processInfo.environment["SHORTREEL_EXPORT_WATCH_FIXTURES"] {
            try JSONSerialization.data(withJSONObject: fixtures, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: path))
        } else {
            let saved = try JSONSerialization.jsonObject(with: Data(contentsOf:
                URL(fileURLWithPath: "SemanticIf/Tests/SemanticIfTests/Fixtures/tiktok-watch-transitions.json"))) as! [[String: Any]]
            try T.expect(NSArray(array: fixtures).isEqual(to: saved), "Native classifier fixtures differ from the actual runner questions")
        }
        for (reading, allowed) in [("10K", false), ("10.0K", false), ("10,000", false), ("10.1K", true), ("25.4K", true)] {
            let selected = PhoneWatchChecks.branch(for: "player", check: .popularVideo,
                evidence: "Heart count: \(reading)", duration: nil, replay: false, advanceSent: false)
            try T.expect(selected == (allowed ? "qualified" : "below"), "Heart threshold misread \(reading)")
        }
        try T.expect(!PhoneTransactionPlan.validWatchQuery("one two three"), "Allowed an overlong query")
        var tracker = PhoneVideoProgressTracker()
        let date = Date()
        func video(_ progress: Double, _ creator: String = "@one") -> PhoneScreenObservation.Video {
            .init(creator: creator, caption: "Stable caption for video", progress: progress, durationSeconds: 10, playing: true)
        }
        _ = tracker.observe(video(0.6), at: date)
        _ = tracker.observe(video(0.95), at: date.addingTimeInterval(4))
        try T.expect(!tracker.observe(video(0.01, "@two"), at: date.addingTimeInterval(5)).replayCandidate, "A different video counted as a replay")
        tracker.reset()
        _ = tracker.observe(video(0.95), at: date)
        try T.expect(!tracker.observe(video(0.01), at: date.addingTimeInterval(4)).replayCandidate,
            "A timer reset without observed forward progress counted as a view")
        tracker.reset()
        func longVideo(_ progress: Double, duration: Double? = nil) -> PhoneScreenObservation.Video {
            .init(creator: "@one", caption: "A stable video caption", progress: progress, durationSeconds: duration, playing: true)
        }
        _ = tracker.observe(longVideo(0.1), at: date)
        _ = tracker.observe(longVideo(0.14), at: date.addingTimeInterval(4))
        let estimated = tracker.observe(longVideo(0.18), at: date.addingTimeInterval(8))
        try T.expect((estimated.durationSeconds ?? 0) > 60, "Two consistent progress intervals did not establish an overlong video")
        let readable = tracker.observe(longVideo(0.22, duration: 30), at: date.addingTimeInterval(12))
        try T.expect(readable.durationSeconds == 30, "Estimated duration overrode the readable duration")
        let observe = rig.observeOverride!
        rig.actions = []; rig.captures = 0; rig.locatorCalls = 0; asked = 0
        rig.readTextOverride = { frame, platform in
            .init(sourceID: frame.sourceID, capturedAt: frame.capturedAt, platform: platform, regions: [])
        }
        rig.classifyOverride = { question in
            if question.id == "search.field.verify" { return "confirmed" }
            return nextScreen().selected
        }
        let fieldVerify = captured.firstIndex { $0.id == "search.field.verify" }! + 1
        rig.observeOverride = { frame, question in
            if rig.captures >= fieldVerify { return .init(state: .foregroundApp, appCardsVisible: false, evidence: empty, checkEvidence: empty) }
            return try await observe(frame, question)
        }
        try await T.rejects { _ = try await rig.run(workflow: .warmUp, script: script) }
        try T.expect(rig.actions.last == .typeText("swing trading") && !rig.actions.contains(.swipe(.up)), "Missing query allowed browsing")
        rig.actions = []; rig.captures = 0; rig.locatorCalls = 0; asked = 0
        rig.readTextOverride = { frame, platform in
            .init(sourceID: frame.sourceID, capturedAt: frame.capturedAt, platform: platform,
                regions: [.init(text: "swing trading", confidence: 1, bounds: .init(x: 0.1, y: 0.1, width: 0.5, height: 0.03))])
        }
        let advanceVerify = captured.firstIndex { $0.id == "advance.player.verify" }! + 1
        rig.observeOverride = { frame, question in
            if rig.captures >= advanceVerify {
                return .init(state: .foregroundApp, appCardsVisible: false, evidence: player, checkEvidence: player,
                    video: .init(creator: "@creator1", caption: "A swing trading setup number 1", progress: 0.1, durationSeconds: 10, playing: true))
            }
            return try await observe(frame, question)
        }
        rig.classifyOverride = { question in
            question.id == "advance.player.verify" ? "player" : nextScreen().selected
        }
        try await T.rejects { _ = try await rig.run(workflow: .warmUp, script: script) }
        try T.expect(rig.actions.filter { $0 == .swipe(.up) }.count == 1 && rig.captures == advanceVerify + 2,
            "An unchanged item was counted or caused a second swipe")
        print("TikTok watch flow passed: account → search → suggestion → results → two watched videos, one swipe")
    }
}
