import CoreGraphics
import Foundation

@main @MainActor enum PhoneWatchFlowTests {
    typealias T = TransactionTestSupport
    typealias Video = PhoneScreenObservation.Video
    struct Frame {
        var state: PhoneScreenObservation.State = .foregroundApp
        let evidence: String
        var text: [(String, Double)] = []
        var keyboard: Bool? = nil
        var video: Video? = nil
        var reading = ""
    }
    struct Flow {
        let script: WarmUpScript
        let query: String
        let frames: [Frame]
        let answers: [String: [String]]
    }
    struct Run {
        let rig: T.Rig
        let result: String
        let fixtures: [[String: Any]]
    }

    static func video(_ creator: String, _ caption: String, _ progress: Double?, liked: Bool? = nil, follow: Bool? = nil) -> Video {
        .init(creator: creator, caption: caption, progress: progress, durationSeconds: 10, playing: true, liked: liked, followButtonVisible: follow)
    }
    static func keys(_ rows: [(String, Double)]) -> [(String, Double)] {
        rows + "QWERTYUIOP".map { (String($0), 0.62) }
    }
    static func template(_ network: WarmUpScript.Network) throws -> Data {
        try Data(contentsOf: URL(fileURLWithPath: "Contracts/\(PhoneTransactionCompiler.watchTemplateName(for: network)).json"))
    }

    static func run(_ flow: Flow, store: WarmUpContractStore, rig: T.Rig = T.Rig(), frames override: ((Int) -> Frame?)? = nil,
                    answer: ((PhoneTransactionQuestion) -> String?)? = nil, closable: Bool = true) async throws -> Run {
        rig.plan = try PhoneTransactionCompiler.watch(script: flow.script, query: flow.query, template: template(flow.script.network))
        rig.locate = { goal, _, _ in
            goal.contains(PhoneTransactionCompiler.interruptTarget) && !closable ? .needsInput("No safe close control is visible.")
                : .action(.tap(Double(rig.locatorCalls % 8 + 1) / 10, 0.5), reason: "Located the declared control")
        }
        rig.budgetOverride = { store.step(scriptIdentifier: $0.identifier, stepID: $1.rawValue)?.budget }
        func frame() throws -> Frame {
            guard rig.captures <= flow.frames.count || override != nil else { throw T.Failure.assertion("Workflow took an unexpected extra observation") }
            return override?(rig.captures) ?? flow.frames[min(rig.captures, flow.frames.count) - 1]
        }
        rig.observeOverride = { _, _ in
            let current = try frame()
            return .init(state: current.state, appCardsVisible: false, evidence: current.evidence + current.reading,
                checkEvidence: current.evidence, keyboardVisible: current.keyboard, video: current.video)
        }
        rig.readTextOverride = { captured, platform in
            let rows = (try? frame())?.text ?? []
            return .init(sourceID: captured.sourceID, capturedAt: captured.capturedAt, platform: platform,
                regions: rows.map { .init(text: $0.0, confidence: 0.99, bounds: CGRect(x: 0.2, y: $0.1, width: 0.3, height: 0.016)) })
        }
        var fixtures: [[String: Any]] = []
        var asked: [String: Int] = [:]
        rig.classifyOverride = { question in
            let queue = flow.answers[question.id] ?? []
            defer { asked[question.id, default: 0] += 1 }
            guard let expected = answer?(question) ?? (queue.isEmpty ? nil : queue[min(asked[question.id, default: 0], queue.count - 1)]) else {
                throw T.Failure.assertion("\(flow.script.network.rawValue): unexpected Laya question \(question.id) with \(question.options.map(\.id))")
            }
            fixtures.append(["id": question.id, "state": question.evidence, "question": question.question,
                "options": question.options.map { ["id": $0.id, "description": $0.description] }, "expected": expected])
            return expected
        }
        let result = try await rig.run(workflow: .warmUp, script: flow.script)
        return .init(rig: rig, result: result, fixtures: fixtures)
    }

    static func check(_ flow: Flow, store: WarmUpContractStore, fixture: String? = nil) async throws -> Run {
        let network = flow.script.network
        let run = try await run(flow, store: store)
        let name = network.rawValue
        try T.expect(run.result.contains("Verified \(flow.script.itemLimit) item(s)"), "\(name): did not complete every item: \(run.result)")
        try T.expect(run.rig.actions.filter { $0 == .swipe(.up) }.count == flow.script.itemLimit - 1, "\(name): expected one swipe between items")
        try T.expect(run.rig.actions.filter { $0 == .typeText(flow.query) }.count == 1, "\(name): did not type the niche query once")
        try T.expect(run.rig.accountCalls == 1 && run.rig.captures == flow.frames.count, "\(name): account checks or observations drifted")
        try T.expect(run.rig.records.filter { $0.source == .laya }.count == run.fixtures.count, "\(name): Laya decisions were not all captured")
        let file = "SemanticIf/Tests/SemanticIfTests/Fixtures/\(fixture ?? name.lowercased() + "-watch-transitions").json"
        if let directory = ProcessInfo.processInfo.environment["SHORTREEL_EXPORT_WATCH_FIXTURES"] {
            try JSONSerialization.data(withJSONObject: run.fixtures, options: [.prettyPrinted, .sortedKeys])
                .write(to: URL(fileURLWithPath: directory).appendingPathComponent(URL(fileURLWithPath: file).lastPathComponent))
        } else {
            let saved = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: file))) as! [[String: Any]]
            try T.expect(NSArray(array: run.fixtures).isEqual(to: saved), "\(name): native classifier fixtures differ from the actual runner questions")
        }
        return run
    }

    static let home = Frame(state: .home, evidence: "The Home Screen shows an empty grid, a Search pill, and a Dock with YouTube, TikTok, Instagram, and X.",
        text: [("9:41", 0.02), ("Search", 0.86)])

    static func tikTok(engaged: Bool = false) -> Flow {
        let tabs: [(String, Double)] = [("Home", 0.944), ("Friends", 0.944), ("Inbox", 0.944), ("Profile", 0.944)]
        let feed = Frame(evidence: "TikTok is open on the For You feed with a playing video, a right-side icon rail, and the bottom navigation.",
            text: [("9:41", 0.02), ("LIVE", 0.065), ("Following", 0.065), ("For You", 0.065), ("25.4K", 0.5), ("@creator0", 0.8),
                   ("Morning market recap for swing traders", 0.83)] + tabs, video: video("@creator0", "Morning market recap", 0.3))
        let profile = Frame(evidence: "TikTok profile page with the username, handle, Following, Followers, and Likes counts, and the Profile tab selected.",
            text: [("9:41", 0.02), ("toptopnonstop99", 0.14), ("@toptopnonstop99", 0.18), ("Following", 0.24), ("Followers", 0.24), ("Likes", 0.24)] + tabs)
        let search = Frame(evidence: "The TikTok search page has a focused search field, a Search button, and a You may like list, with the keyboard open.",
            text: keys([("9:41", 0.02), ("Search", 0.066), ("You may like", 0.14), ("halloween costumes", 0.19)]), keyboard: true)
        let typed = Frame(evidence: "The search field holds the typed words with a clear button, and a list of search suggestions sits above the keyboard.",
            text: keys([("9:41", 0.02), ("swing trading", 0.066), ("Search", 0.066), ("swing trading strategy", 0.14),
                        ("swing trading for beginners", 0.19), ("swing trading setups", 0.24)]), keyboard: true)
        let resultTabs: [(String, Double)] = [("Top", 0.112), ("Videos", 0.112), ("Users", 0.112), ("Sounds", 0.112), ("Shop", 0.112), ("LIVE", 0.112)]
        let top = Frame(evidence: "Search results for swing trading strategy open on the Top tab, with user cards and videos below the tab row.",
            text: [("9:41", 0.02), ("swing trading strategy", 0.066)] + resultTabs + [("Swing Trading Academy", 0.2), ("120K followers", 0.23)], keyboard: false)
        let grid = Frame(evidence: "The Videos tab is selected and two columns of video thumbnails with like counts fill the screen.",
            text: [("9:41", 0.02), ("swing trading strategy", 0.066)] + resultTabs + [("12.3K", 0.5), ("Swing trading basics for beginners", 0.53)])
        let live = Frame(evidence: "A LIVE stream is open with a viewer count at the top, floating gifts, and a comment field at the bottom.",
            text: [("9:41", 0.02), ("LIVE", 0.16), ("1.2K", 0.16), ("@streamer", 0.8), ("Say something...", 0.93)],
            video: video("@streamer", "Trading live Q&A", nil))
        let ad = Frame(evidence: "A full-screen video with a Sponsored label and a Learn more button above the caption.",
            text: [("9:41", 0.02), ("Following", 0.065), ("For You", 0.065), ("@brandname", 0.78), ("Sponsored", 0.81), ("Learn more", 0.87)],
            video: video("@brandname", "Trade smarter with our app", 0.1))
        func item(_ number: Int, _ progress: Double, liked: Bool? = nil, follow: Bool? = nil, _ evidence: String = "A full-screen video is playing with the right-side icon rail and the progress bar along the bottom.") -> Frame {
            Frame(evidence: evidence, text: [("9:41", 0.02), ("@creator\(number)", 0.8), ("A swing trading setup number \(number)", 0.83)],
                video: video("@creator\(number)", "A swing trading setup number \(number)", progress, liked: liked, follow: follow))
        }
        var candidate = item(1, 0.05, "A full-screen video with the heart button and its like count on the right rail.")
        candidate.reading = " Heart count: 25.4K"
        var frames = [home, home, feed, profile, profile, feed, search, search, typed, top, grid, live, live, grid, ad, ad, grid, item(1, 0.05), candidate,
                      item(1, 0.6), item(1, 0.95), item(1, 0.01)]
        if engaged {
            frames += [item(1, 0.1, liked: false, follow: true, "A full-screen video with an outlined white heart on the right rail."),
                       item(1, 0.2, liked: true, follow: true, "A full-screen video with a filled red heart on the right rail."),
                       item(1, 0.3, liked: true, follow: true, "A full-screen video with a red plus badge under the creator's round avatar."),
                       item(1, 0.4, liked: true, follow: false, "A full-screen video with a checkmark under the creator's round avatar.")]
        }
        frames += [item(1, 0.1), item(2, 0.1, "A different full-screen video is playing with the right-side icon rail."), item(2, 0.6), item(2, 0.95), item(2, 0.01)]
        return Flow(script: WarmUpScript(network: .tikTok, activity: .watch, itemLimit: 2, duration: 600,
                likeLimit: engaged ? 1 : 0, followLimit: engaged ? 1 : 0), query: "swing trading", frames: frames, answers: [
            "account.launcher.verify": ["confirmed"], "search.feed.verify": ["confirmed"], "suggestion.suggestions": ["suggestions"],
            "open.player0": ["live"], "open.player2": ["player"], "advance.player": ["player"], "advance.player.verify": ["player"],
            "like.heart": ["unliked"], "like.heart.verify": ["confirmed"], "follow.badge": ["available"], "follow.badge.verify": ["confirmed"]])
    }

    static func instagram() -> Flow {
        let feed = Frame(evidence: "Instagram is open on the home feed with stories at the top, a photo post, and tab icons along the bottom.",
            text: [("9:41", 0.02), ("Instagram", 0.065), ("creator1", 0.14), ("Liked by friend and others", 0.7), ("creator1 great morning pour", 0.73)])
        let profile = Frame(evidence: "Instagram profile with the username at the top, post, follower, and following counts, and Edit profile and Share profile buttons.",
            text: [("9:41", 0.02), ("toptopnonstop99", 0.07), ("posts", 0.17), ("followers", 0.17), ("following", 0.17), ("Trading every day", 0.22),
                   ("Edit profile", 0.28), ("Share profile", 0.28)])
        let explore = Frame(evidence: "The Explore page shows a search bar at the top above a grid of photos and videos, with the keyboard hidden.",
            text: [("9:41", 0.02), ("Ask Meta AI or Search", 0.066)], keyboard: false)
        let focused = Frame(evidence: "The search bar is focused with Cancel beside it and recent searches below, and the keyboard is open.",
            text: keys([("9:41", 0.02), ("Ask Meta AI or Search", 0.066), ("Cancel", 0.066), ("Recent", 0.14)]), keyboard: true)
        let typed = Frame(evidence: "Under the search field, suggested searches and account rows are listed above the keyboard.",
            text: keys([("9:41", 0.02), ("latte art", 0.066), ("Cancel", 0.066), ("latte art tutorial", 0.14), ("latte art heart", 0.19),
                        ("@latteartdaily", 0.24)]), keyboard: true)
        let tabs: [(String, Double)] = [("For you", 0.118), ("Accounts", 0.118), ("Reels", 0.118), ("Audio", 0.118), ("Tags", 0.118)]
        let results = Frame(evidence: "Search results for latte art open on the For you tab, with a row of tabs and a grid of posts.",
            text: [("9:41", 0.02), ("latte art", 0.066)] + tabs, keyboard: false)
        let reels = Frame(evidence: "The Reels tab is selected and a three-column grid of Reel thumbnails with view counts is shown.",
            text: [("9:41", 0.02), ("latte art", 0.066)] + tabs + [("12.4K", 0.4), ("8,120", 0.4)], keyboard: false)
        let ad = Frame(evidence: "A full-screen Reel with a Sponsored label and a Shop now button above the caption.",
            text: [("9:41", 0.02), ("brandname", 0.8), ("Sponsored", 0.82), ("Shop now", 0.88)], video: video("brandname", "Fresh beans every week", 0.1))
        func captionless(_ progress: Double) -> Frame {
            Frame(evidence: "A full-screen Reel is playing with like, comment, and share icons on the right.",
                text: [("9:41", 0.02), ("@latteguy", 0.8), ("latteguy · Original audio track", 0.86)], video: video("latteguy", "", progress))
        }
        func second(_ progress: Double, _ evidence: String = "A full-screen Reel is playing with like, comment, and share icons on the right.") -> Frame {
            Frame(evidence: evidence, text: [("9:41", 0.02), ("@barista", 0.8), ("Tulip pour in slow motion", 0.84)],
                video: video("@barista", "Tulip pour in slow motion", progress))
        }
        return Flow(script: WarmUpScript(network: .instagram, activity: .watch, itemLimit: 2, duration: 600), query: "latte art",
            frames: [home, home, feed, profile, profile, explore, focused, focused, typed, results, reels, ad, reels, captionless(0.05),
                     captionless(0.6), captionless(0.95), captionless(0.01), captionless(0.1),
                     second(0.1, "A different full-screen Reel is playing with like, comment, and share icons on the right."),
                     second(0.6), second(0.95), second(0.01)],
            answers: ["account.launcher.verify": ["confirmed"], "search.start.verify": ["confirmed"], "search.typed": ["suggestions"],
                      "advance.player": ["player"], "advance.player.verify": ["player"]])
    }

    static func youtube() -> Flow {
        let tabs: [(String, Double)] = [("Home", 0.944), ("Shorts", 0.944), ("Subscriptions", 0.944), ("You", 0.944)]
        let feed = Frame(evidence: "YouTube Home feed with topic chips under the top bar, video thumbnails, and the bottom tabs.",
            text: [("9:41", 0.02), ("YouTube", 0.065), ("All", 0.115), ("Music", 0.115), ("Live", 0.115), ("Recently uploaded", 0.115)] + tabs)
        let you = Frame(evidence: "The You page shows the channel name and handle with View channel, then Switch account, Google Account, and History.",
            text: [("9:41", 0.02), ("Joe Blau", 0.1), ("@toptopnonstop99 • View channel >", 0.13), ("Switch account", 0.18), ("Google Account", 0.18),
                   ("History", 0.25)] + tabs)
        let search = Frame(evidence: "A search field at the top shows Search YouTube with recent searches below and the keyboard open.",
            text: keys([("9:41", 0.02), ("Search YouTube", 0.066), ("coffee grinder review", 0.14)]), keyboard: true)
        let typed = Frame(evidence: "The search field holds the typed words and autocomplete rows are listed above the keyboard.",
            text: keys([("9:41", 0.02), ("latte art", 0.066), ("latte art tutorial", 0.14), ("latte art for beginners", 0.19)]), keyboard: true)
        let chips: [(String, Double)] = [("All", 0.115), ("Shorts", 0.115), ("Videos", 0.115), ("Unwatched", 0.115)]
        let results = Frame(evidence: "Search results for latte art with a row of filter chips and wide video rows with durations.",
            text: [("9:41", 0.02), ("latte art", 0.066)] + chips + [("12:34", 0.3), ("Latte Art for Beginners", 0.33)], keyboard: false)
        let grid = Frame(evidence: "The Shorts chip is selected and a two-column grid of tall Short thumbnails with view counts is shown.",
            text: [("9:41", 0.02), ("latte art", 0.066)] + chips + [("1.2M views", 0.5), ("840K views", 0.5)], keyboard: false)
        let ad = Frame(evidence: "A vertical Short with a Sponsored label and an Install button above the channel name.",
            text: [("9:41", 0.02), ("Sponsored", 0.8), ("@brand", 0.84), ("Install", 0.86)], video: video("@brand", "Try the new grinder", 0.1))
        func captionless(_ progress: Double) -> Frame {
            Frame(evidence: "A vertical Short is playing with like, dislike, comment, and share icons on the right.",
                text: [("9:41", 0.02), ("@lattelab", 0.8), ("Original sound - lattelab studio", 0.86)], video: video("@lattelab", "", progress))
        }
        func second(_ progress: Double, _ evidence: String = "A vertical Short is playing with like, dislike, comment, and share icons on the right.") -> Frame {
            Frame(evidence: evidence, text: [("9:41", 0.02), ("@cafecrew", 0.8), ("Rosetta pour step by step", 0.84)],
                video: video("@cafecrew", "Rosetta pour step by step", progress))
        }
        let sheet = Frame(state: .dialog, evidence: "A YouTube Premium sheet covers the lower half of the Short with Try it free and No thanks.",
            text: [("9:41", 0.02), ("YouTube Premium", 0.55), ("Try it free", 0.8), ("No thanks", 0.86)])
        return Flow(script: WarmUpScript(network: .youtube, activity: .watch, itemLimit: 2, duration: 600), query: "latte art",
            frames: [home, home, feed, you, you, feed, search, search, typed, results, grid, ad, grid, captionless(0.05),
                     captionless(0.6), sheet, captionless(0.3), captionless(0.35), captionless(0.95), captionless(0.01), captionless(0.1),
                     second(0.1, "A different vertical Short is playing with like, dislike, comment, and share icons on the right."),
                     second(0.6), second(0.95), second(0.01)],
            answers: ["account.launcher.verify": ["confirmed"], "search.feed.verify": ["confirmed"],
                      "advance.player": ["player"], "advance.player.verify": ["player"]])
    }

    static func x() -> Flow {
        let spotlight = Frame(state: .spotlight, evidence: "Spotlight search is open with an empty search field, Siri Suggestions, and the keyboard.",
            text: keys([("9:41", 0.02), ("Search", 0.07), ("Siri Suggestions", 0.14)]), keyboard: true)
        let found = Frame(state: .spotlight, evidence: "Spotlight lists X as the top hit app, with suggested websites below.",
            text: keys([("9:41", 0.02), ("X", 0.07), ("Top Hit", 0.1), ("X", 0.13), ("Siri Suggested Websites", 0.3), ("x.com", 0.33)]), keyboard: true)
        let timeline = Frame(evidence: "X is open on the home timeline with For you and Following tabs and a round profile picture at the top left.",
            text: [("9:41", 0.02), ("For you", 0.1), ("Following", 0.1), ("Jane Doe @janedoe · 2h", 0.16), ("Markets opened higher this morning", 0.19), ("12", 0.3)])
        let drawer = Frame(evidence: "The account side menu is open with the display name, handle, Following and Followers, Profile, Premium, Bookmarks, and Lists.",
            text: [("9:41", 0.02), ("Joe Blau", 0.12), ("@toptopnonstop99", 0.15), ("123 Following", 0.19), ("45 Followers", 0.19),
                   ("Profile", 0.28), ("Premium", 0.34), ("Bookmarks", 0.4), ("Lists", 0.46)])
        let explore = Frame(evidence: "The Explore page shows a Search field at the top and trending topics below, with the keyboard hidden.",
            text: [("9:41", 0.02), ("Search", 0.066), ("Trending in United States", 0.2), ("#MarketOpen", 0.23)], keyboard: false)
        let focused = Frame(evidence: "The search field is focused with Cancel beside it and the keyboard open.",
            text: keys([("9:41", 0.02), ("Search", 0.066), ("Cancel", 0.066), ("Try searching for people, lists, or keywords", 0.14)]), keyboard: true)
        let typed = Frame(evidence: "The search field holds the typed words with suggestions listed above the keyboard.",
            text: keys([("9:41", 0.02), ("latte art", 0.066), ("Cancel", 0.066), ("latte art class", 0.14)]), keyboard: true)
        let tabs: [(String, Double)] = [("Top", 0.112), ("Latest", 0.112), ("People", 0.112), ("Media", 0.112), ("Lists", 0.112)]
        let top = Frame(evidence: "Search results for latte art with Top, Latest, People, and Media tabs above a feed of posts.",
            text: [("9:41", 0.02), ("latte art", 0.066)] + tabs + [("Cafe Luna @cafeluna · 1h", 0.16), ("Our latte art class is back this weekend", 0.19)], keyboard: false)
        func post(_ author: String, _ line: String, _ evidence: String) -> Frame {
            Frame(evidence: evidence, text: [("9:41", 0.02), ("latte art", 0.066)] + tabs + [(author, 0.16), (line, 0.19), ("3 12 48", 0.3)], keyboard: false)
        }
        let first = post("Jane Doe @janedoe · 2m", "Poured my first latte art rosetta today",
                         "The Latest tab is selected and lists posts; the top one has an author name, handle, time, and a line of text with a photo.")
        let reading = post("Jane Doe @janedoe · 2m", "Poured my first latte art rosetta today",
                           "The top post shows the author, handle, a line of text, and a photo of a latte with reply and like counts.")
        let next = post("Sam Lee @samlee · 5m", "Latte art practice with oat milk",
                        "The top post shows the author, handle, a line of text, and a photo of a latte with reply and like counts.")
        return Flow(script: WarmUpScript(network: .x, activity: .watch, itemLimit: 2, duration: 600), query: "latte art",
            frames: [home, home, spotlight, spotlight, found, timeline, drawer, drawer, timeline, explore, focused, focused, typed, top, first,
                     reading, reading, reading, reading, reading, next, next, next, next, next],
            answers: ["account.launcher.verify": ["confirmed"], "account.replace.verify": ["confirmed"],
                      "account.result.verify": ["confirmed"], "account.profile": ["avatar"],
                      "search.start.verify": ["confirmed"], "search.start": ["tabs"], "open.first": ["original"],
                      "consume.read.verify": ["confirmed"], "consume.skim.verify": ["confirmed"]])
    }

    static func main() async throws {
        let store = try WarmUpContractStore(data: Data(contentsOf: URL(fileURLWithPath: "Contracts/warmup-tasks.json")))
        for network in WarmUpScript.Network.allCases {
            for engaged in network == .tikTok ? [false, true] : [false] {
                let script = WarmUpScript(network: network, activity: .watch, itemLimit: 2, duration: 600,
                    likeLimit: engaged ? 1 : 0, followLimit: engaged ? 1 : 0)
                let plan = try PhoneTransactionCompiler.watch(script: script, query: "latte art", template: template(network))
                try T.expect(plan.phases.map(\.id) == script.steps.map(\.id.rawValue) && plan.watchQuery == "latte art",
                    "\(network.rawValue) watch plan phases differ from its script steps")
                try T.expect(plan.phases.contains { $0.id == "like" } == engaged, "\(network.rawValue): engagement phases do not follow the script")
                try T.expect(network != .x || !plan.phases.flatMap(\.states).contains { $0.check != nil && $0.check != .query },
                    "X posts have no video player, so its template must not use video checks")
            }
        }

        let watched = try await check(tikTok(), store: store)
        try T.expect(watched.rig.records.contains { $0.question?.id == "open.player0" && $0.selected == "live" }
            && watched.rig.records.contains { $0.question?.id == "open.player1" && $0.selected == "ad" && $0.source == .deterministic },
            "TikTok: a LIVE room or a Sponsored video was not rejected before counting")
        try T.expect(watched.rig.records.filter { $0.source == .laya }.count == 6
            && watched.rig.records.contains { $0.phase == "advance" && $0.pending == "ready" && $0.source == .deterministic && $0.selected == "confirmed" }
            && watched.rig.accountObservations.first?.checkEvidence == tikTok().frames[3].evidence,
            "TikTok: Laya was asked beyond the ambiguous states, the next video's new identity did not confirm the swipe, or the profile's evidence missed the account check")
        let engaged = try await check(tikTok(engaged: true), store: store, fixture: "tiktok-watch-engagement")
        func engagement(_ run: Run, _ state: String) -> [String] {
            run.rig.records.filter { $0.state == state }.map { "\($0.pending ?? "-").\($0.selected ?? "-").\($0.source.rawValue)" }
        }
        try T.expect(engaged.result.contains("Verified 2 item(s)") && engaged.rig.actions.filter { $0 == .swipe(.up) }.count == 1
            && engagement(engaged, "heart") == ["-.unliked.short-circuit", "unliked.confirmed.deterministic"]
            && engagement(engaged, "badge") == ["-.available.short-circuit", "available.confirmed.deterministic"]
            && !engaged.rig.questions.contains { $0.id.hasPrefix("like.") || $0.id.hasPrefix("follow.") },
            "TikTok: like and follow did not follow the structured reading and verify its flip before the single advance swipe")
        let reels = try await check(instagram(), store: store)
        let shorts = try await check(youtube(), store: store)
        for (name, run) in [("Instagram", reels), ("YouTube", shorts)] {
            try T.expect(run.rig.records.contains { $0.phase == "open" && $0.selected == "sponsored" && $0.source == .shortCircuit }
                && run.rig.records.contains { $0.phase == "advance" && $0.pending == nil && $0.observation.video?.caption == "" },
                "\(name): the ad was not skipped deterministically, or the captionless item did not complete by its OCR identity")
        }
        try T.expect(shorts.rig.records.contains { $0.pending == "playing" && $0.observation.state == .dialog && $0.selected == nil }
            && shorts.rig.records.contains { $0.state == "playback" && $0.selected == "prompt" && $0.source == .shortCircuit }
            && shorts.rig.records.contains { $0.state == "playback" && $0.pending == "prompt" && $0.selected == "confirmed" && $0.source == .deterministic },
            "YouTube: a sheet during playback was not dismissed without Laya and verified by the returning player")
        let posts = try await check(x(), store: store)
        try T.expect(!posts.rig.questions.contains { $0.id.hasPrefix("advance.") || $0.id == "open.first" }
            && posts.rig.records.contains { $0.state == "first" && $0.selected == "original" && $0.source == .shortCircuit }
            && posts.rig.records.contains { $0.phase == "advance" && $0.pending == "feed" && $0.source == .deterministic },
            "X: the first post or the feed scroll asked Laya instead of reading the author row and comparing post identities")

        try await negativeTikTok(store: store)
        let flow = youtube()
        let sheet = flow.frames.firstIndex { $0.state == .dialog }!
        var undismissable = flow.frames[sheet]
        undismissable.text.removeAll { $0.0 == "No thanks" }
        let blocked = try await failing(flow, store: store, from: sheet + 1, show: undismissable, closable: false)
        try T.expect(!blocked.actions.contains(.home) && !blocked.records.contains { $0.selected == "prompt" || $0.selected == "dismiss" }
            && blocked.actions.filter { if case .typeText = $0 { true } else { false } }.count == 1,
            "YouTube: a sheet without a dismiss control was tapped, or the watch loop went back to Home and search: \(blocked.actions)")
        try await engagementGuards(store: store)
        try await longVideoSkip(store: store)
        try await captionlessAdvance(store: store)
        try units()
        print("Watch flow passed for TikTok, Instagram, YouTube, and X: account → search → open → consume → advance with contract budgets, ads and LIVE skipped, captionless items, playback sheets, like + follow")
    }

    /// Runs a flow that must fail, returning its rig; test assertions still propagate.
    static func failing(_ flow: Flow, store: WarmUpContractStore, from capture: Int, show frame: Frame, closable: Bool = true) async throws -> T.Rig {
        let rig = T.Rig()
        let completed: Bool
        do {
            _ = try await run(flow, store: store, rig: rig, frames: { $0 >= capture ? frame : nil },
                answer: { $0.id.hasSuffix(".verify") && $0.id != "advance.player.verify" ? "confirmed" : nil }, closable: closable)
            completed = true
        } catch let error as T.Failure { throw error } catch { completed = false }
        try T.expect(!completed, "\(flow.script.network.rawValue): the run completed on an unverified frame")
        return rig
    }

    static func negativeTikTok(store: WarmUpContractStore) async throws {
        let flow = tikTok()
        let typed = flow.frames.firstIndex { $0.text.contains { $0.0 == "swing trading" } }! + 1
        let untyped = try await failing(flow, store: store, from: typed, show: flow.frames[typed - 2])
        let afterTyping = untyped.actions.drop { $0 != .typeText("swing trading") }.dropFirst()
        try T.expect(untyped.actions.filter { $0 == .typeText("swing trading") }.count == 1 && !untyped.actions.contains(.swipe(.up))
            && afterTyping.first == .home && !afterTyping.contains { if case .swipe = $0 { true } else { false } },
            "A missing query allowed browsing instead of restarting from Home")
        let swiped = flow.frames.lastIndex { $0.video?.caption.hasSuffix("number 1") == true && $0.video?.progress == 0.1 }! + 2
        let same = try await failing(flow, store: store, from: swiped, show: flow.frames[swiped - 2])
        try T.expect(same.actions.filter { $0 == .swipe(.up) }.count == 1 + PhoneVisualRunner.maximumResumes
            && !same.actions.contains(.home) && same.actions.filter { if case .typeText = $0 { true } else { false } }.count == 1
            && same.questions.contains { $0.id == "advance.player.verify" } && !same.questions.contains { $0.id.hasPrefix("consume.") && same.captures > 200 },
            "A swipe that did not move was not sent again in place, or the run went back to Home and search: \(same.actions)")
    }

    /// Live run 2026-09-27: a video judged too long after more consume checks than the advance budget allows must still verify its skip swipe.
    static func longVideoSkip(store: WarmUpContractStore) async throws {
        let base = tikTok()
        let qualified = base.frames.firstIndex { $0.reading.contains("Heart count") }!
        func long(_ progress: Double, duration: Double?) -> Frame {
            Frame(evidence: "A full-screen video is playing with the right-side icon rail and the progress bar along the bottom.",
                text: [("9:41", 0.02), ("@creator1", 0.8), ("A swing trading setup number 1", 0.83)],
                video: .init(creator: "@creator1", caption: "A swing trading setup number 1", progress: progress, durationSeconds: duration, playing: true))
        }
        func next(_ progress: Double) -> Frame {
            Frame(evidence: "A different full-screen video is playing with the right-side icon rail.",
                text: [("9:41", 0.02), ("@creator2", 0.8), ("A swing trading setup number 2", 0.83)], video: video("@creator2", "A swing trading setup number 2", progress))
        }
        let frames = Array(base.frames.prefix(qualified + 1)) + (1...6).map { long(0.1 * Double($0), duration: nil) } + [long(0.7, duration: 150)]
            + [0.1, 0.1, 0.2, 0.4, 0.6, 0.8, 0.95, 0.01, 0.1, 0.3, 0.5, 0.7, 0.9, 0.99, 0.02, 0.1, 0.2].map(next)
        let flow = Flow(script: WarmUpScript(network: .tikTok, activity: .watch, itemLimit: 1, duration: 600), query: base.query,
            frames: frames, answers: base.answers)
        let run = try await run(flow, store: store)
        try T.expect(run.result.contains("Verified 1 item(s)") && run.rig.actions.filter { $0 == .swipe(.up) }.count == 1
            && run.rig.records.contains { $0.phase == "consume" && $0.pending == "too-long" && $0.selected == "confirmed" },
            "A long video skipped after more consume checks than the advance budget stopped at the request limit: \(run.result)")
    }

    /// Review 2026-09-27: an advance frame whose creator and caption are unreadable must not re-watch and recount the finished item.
    static func captionlessAdvance(store: WarmUpContractStore) async throws {
        let base = tikTok()
        let advance = base.frames.lastIndex { $0.video?.caption.hasSuffix("number 1") == true && $0.video?.progress == 0.1 }!
        var frames = base.frames
        frames.insert(Frame(evidence: "A full-screen video is playing with the right-side icon rail.", text: [("9:41", 0.02)],
            video: .init(creator: "", caption: "", progress: 0.1, durationSeconds: 10, playing: true)), at: advance)
        let flow = Flow(script: base.script, query: base.query, frames: frames, answers: base.answers)
        let run = try await run(flow, store: store)
        try T.expect(run.result.contains("Verified 2 item(s)") && run.rig.actions.filter { $0 == .swipe(.up) }.count == 1
            && !run.rig.actions.contains(.home),
            "An unreadable advance frame re-watched and recounted the finished video, or went back to Home: \(run.result) \(run.rig.actions)")
    }

    static func engagementGuards(store: WarmUpContractStore) async throws {
        let flow = tikTok(engaged: true)
        let engaged = try await run(flow, store: store)
        let verify = flow.frames.firstIndex { $0.video?.liked == true }!
        var unconfirmed = flow.frames
        unconfirmed[verify].video = video("@creator1", "A swing trading setup number 1", 0.2, liked: false, follow: true)
        unconfirmed.insert(contentsOf: [unconfirmed[verify], unconfirmed[verify]], at: verify)
        let skipped = try await run(.init(script: flow.script, query: flow.query, frames: unconfirmed, answers: flow.answers), store: store)
        try T.expect(skipped.result.contains("Verified 2 item(s)") && skipped.rig.actions == engaged.rig.actions
            && skipped.rig.records.filter { $0.state == "heart" && $0.pending == nil }.count == 1
            && skipped.rig.records.filter { $0.state == "heart" && $0.pending == "unliked" }.allSatisfy { $0.selected == nil && $0.source == .deterministic }
            && skipped.rig.records.contains { $0.state == "badge" && $0.pending == "available" && $0.selected == "confirmed" },
            "An unconfirmed like was retapped or stopped the run instead of being skipped")
        var unread = flow.frames
        unread[verify - 1].video = video("@creator1", "A swing trading setup number 1", 0.1, follow: true)
        unread.remove(at: verify)
        let blind = try await run(.init(script: flow.script, query: flow.query, frames: unread, answers: flow.answers), store: store)
        try T.expect(blind.result.contains("Verified 2 item(s)") && blind.rig.actions.count == engaged.rig.actions.count - 1
            && !blind.rig.records.contains { $0.state == "heart" && $0.selected == "unliked" }
            && blind.rig.records.contains { $0.state == "badge" && $0.pending == "available" && $0.selected == "confirmed" },
            "A heart without a structured liked reading was tapped")
    }

    static func units() throws {
        func field(_ rows: [(String, Double)]) -> PhonePlaybackTracker.Observation {
            .init(sourceID: "s", capturedAt: .now, platform: "TikTok",
                regions: rows.map { .init(text: $0.0, confidence: 1, bounds: CGRect(x: 0.16, y: $0.1, width: 0.5, height: 0.02)) })
        }
        let live = [("Q swing trading", 0.087), ("Search", 0.088), ("• Swing trading strategy", 0.131), ("Q Swing Trading", 0.189)]
        try T.expect(PhoneWatchChecks.queryVisible("swing trading", in: field(live))
            && PhoneWatchChecks.queryVisible("quant trading", in: field([("Q quant trading", 0.09)]))
            && PhoneWatchChecks.queryVisible("swing trading", in: field([("swing trading x", 0.09)]))
            && !PhoneWatchChecks.queryVisible("swing trading", in: field([("Q swing", 0.087), ("Q Swing Trading", 0.189)]))
            && !PhoneWatchChecks.queryVisible("swing trading", in: field([("Q swing trading options", 0.087)])),
            "The live TikTok search field (magnifier read as Q) or a suggestion row decided whether the query was typed")
        let callisto = Video(creator: "CallistoFx", caption: "ULTIMATE SWING STRATEGY TO win in forex🐳 #fypsg #forex #fore", progress: 0.87,
            durationSeconds: nil, playing: true)
        let retold = Video(creator: "CallistoFx", caption: "ULTIMATE SWING STRATEGY 😱 Win in forex🐳 #fypsg #forex #forex", progress: nil,
            durationSeconds: nil, playing: true)
        let other = Video(creator: "CallistoFx", caption: "Why I stopped trading breakouts on Mondays", progress: 0.1, durationSeconds: nil, playing: true)
        try T.expect(PhoneWatchChecks.sameItem(callisto.identity, retold.identity)
            && !PhoneWatchChecks.sameItem(callisto.identity, other.identity)
            && !PhoneWatchChecks.sameItem(callisto.identity, Video(creator: "Sarah", caption: callisto.caption, progress: nil,
                durationSeconds: nil, playing: true).identity),
            "Live caption transcriptions of one TikTok video split it, or different videos or creators were merged")
        var looping = PhoneVideoProgressTracker()
        let start = Date(timeIntervalSince1970: 0)
        _ = looping.observe(Video(creator: callisto.creator, caption: callisto.caption, progress: 0.72, durationSeconds: nil, playing: true), at: start)
        _ = looping.observe(callisto, at: start.addingTimeInterval(9))
        _ = looping.observe(retold, at: start.addingTimeInterval(18))
        let wrapped = looping.observe(Video(creator: callisto.creator, caption: callisto.caption, progress: 0.07, durationSeconds: nil, playing: true),
            at: start.addingTimeInterval(27))
        try T.expect(wrapped.replayCandidate, "The live loop 0.87 → unreadable → 0.07 of one video was not seen as a replay")
        let wrongTab = "This is an in-app search results screen with LIVE underlined as selected and livestream cards."
        try T.expect(PhoneWatchChecks.selectsTab("LIVE", in: [wrongTab]) && !PhoneWatchChecks.selectsTab("Videos", in: [wrongTab])
            && PhoneWatchChecks.selectsTab("Videos", in: ["A grid of video search results with the Videos tab selected."])
            && PhoneWatchChecks.selectsTab("Videos", in: ["This is a video search-results screen with the Videos tab underlined and a two-column grid."])
            && !PhoneWatchChecks.selectsTab("Videos", in: ["Search results with Top selected beside Videos and Users."])
            && !PhoneWatchChecks.selectsTab("Videos", in: ["The Videos tab is not selected yet."]),
            "The live LIVE-for-Videos mis-tap was confirmed, or a stated Videos selection was missed")
        try T.expect(PhoneWatchChecks.selectsTab("Videos", in: ["The Videos tab is now selected."])
            && PhoneWatchChecks.selectsTab("Videos", in: ["Videos is the selected tab."])
            && !PhoneWatchChecks.selectsTab("Videos", in: ["The LIVE tab is selected, showing live videos highlighted with red LIVE badges."])
            && !PhoneWatchChecks.selectsTab("Videos", in: ["The LIVE tab is highlighted the Videos tab is not."])
            && !PhoneWatchChecks.selectsTab("Videos", in: ["The Top tab is selected. Videos selected by editors appear below."]),
            "Review counterexamples: an adverb phrasing was rejected or a different selected tab was accepted")
        func rows(_ items: [(String, Double, Double)]) -> [PhonePlaybackTracker.TextRegion] {
            items.map { .init(text: $0.0, confidence: 1, bounds: CGRect(x: $0.1, y: $0.2, width: 0.12, height: 0.02)) }
        }
        let viewerSheet = rows([("Viewer history turned on", 0.12, 0.68), ("Viewer history", 0.08, 0.93), ("Save", 0.46, 0.96)])
        try T.expect(PhoneWatchChecks.safeDismissTap(x: 0.93, y: 0.36, regions: viewerSheet)
            && !PhoneWatchChecks.safeDismissTap(x: 0.5, y: 0.97, regions: viewerSheet)
            && PhoneWatchChecks.safeDismissTap(x: 0.3, y: 0.81, regions: rows([("Don't Allow", 0.22, 0.8), ("Allow", 0.62, 0.8)]))
            && !PhoneWatchChecks.safeDismissTap(x: 0.68, y: 0.81, regions: rows([("Don't Allow", 0.22, 0.8), ("Allow", 0.62, 0.8)]))
            && !PhoneWatchChecks.safeDismissTap(x: 0.35, y: 0.08, regions: rows([("Follow", 0.3, 0.07)]))
            && PhoneWatchChecks.nearFollow(x: 0.35, y: 0.08, regions: rows([("+ Follow", 0.3, 0.07)]))
            && !PhoneWatchChecks.nearFollow(x: 0.93, y: 0.07, regions: rows([("+ Follow", 0.3, 0.07)])),
            "The interrupt could tap Save, Allow, or Follow, or the live Viewer history close X was refused")
        try T.expect(PhoneWatchChecks.loading(["This is a search results page with Top selected, Videos and Users tabs beside it, and a loading indicator in the results area."])
            && PhoneWatchChecks.loading(["A black surface shows a central cyan-and-red loading spinner."])
            && !PhoneWatchChecks.loading(["The Videos tab is selected and a grid of videos is visible."])
            && !PhoneWatchChecks.loading(["A caption reads: loaded up on SPY calls today."]),
            "The live loading results page was tapped before it settled, or a loaded page was held back")
        try T.expect(PhoneScreenSignal.foregroundApp("TikTok", evidence: "TikTok’s profile page is visible with Profile selected.")
            && !PhoneScreenSignal.foregroundApp("Instagram", evidence: "An Instagram Reel plays a clip with a TikTok watermark.")
            && !PhoneScreenSignal.foregroundApp("Instagram", evidence: "TikTok’s For You feed is showing."),
            "A TikTok screen was taken for an already open Instagram")
        let series = { (caption: String) in Video(creator: "Sean Trades", caption: caption, progress: nil, durationSeconds: nil, playing: true).identity }
        try T.expect(!PhoneWatchChecks.sameItem(series("Day 12 of swing trading #stocks #fyp"), series("Day 13 of swing trading #stocks #fyp"))
            && !PhoneWatchChecks.sameItem(series("How to swing trade stocks"), series("How to swing trade options for beginners"))
            && PhoneWatchChecks.sameItem(series("My exact swing trading process and what I look for"), series("My exact swing trading process and what I look")),
            "A creator's numbered series or a shared caption template merged, or a truncated caption split")
        var landscape = PhoneVideoProgressTracker()
        var lengthy: Int?
        for (index, progress) in [0.05, 0.08, 0.07, 0.09, 0.1, 0.125, 0.14].enumerated() {
            lengthy = landscape.observe(Video(creator: "Trader", caption: "Full swing trading course part one", progress: progress,
                durationSeconds: nil, playing: true), at: start.addingTimeInterval(Double(index) * 9)).durationSeconds
        }
        var minute = PhoneVideoProgressTracker()
        var short: Int?
        for (index, progress) in [0.05, 0.2, 0.33, 0.49, 0.64].enumerated() {
            short = minute.observe(Video(creator: "Trader", caption: "Quick swing setup", progress: progress, durationSeconds: nil, playing: true),
                at: start.addingTimeInterval(Double(index) * 9)).durationSeconds
        }
        try T.expect((lengthy ?? 0) > 60 && short == nil,
            "The live jittery playhead of a ten-minute video was not estimated as too long, or a one-minute clip was: \(lengthy ?? -1) \(short ?? -1)")
        for (reading, allowed) in [("10K", false), ("10.0K", false), ("10,000", false), ("10.1K", true), ("25.4K", true)] {
            let selected = PhoneWatchChecks.branch(for: "player", check: .popularVideo,
                evidence: "Heart count: \(reading)", duration: nil, limit: 60, replay: false, advanceSent: false)
            try T.expect(selected == (allowed ? "qualified" : "below"), "Heart threshold misread \(reading)")
        }
        let clip = Video(creator: "@one", caption: "A caption", progress: 0.4, durationSeconds: 20, playing: nil)
        let paused = Video(creator: "@one", caption: "A caption", progress: 0.4, durationSeconds: 20, playing: false)
        for (check, video, signals, answer) in [(PhoneTransactionPlan.State.Check.playback, Optional(paused), Set<PhoneScreenSignal>(), Optional("paused")),
                                                (.playback, clip, [], nil), (.playback, nil, [], "unknown"), (.popularVideo, clip, [.adLabel], "ad"),
                                                (.popularVideo, clip, [], nil), (.advance, nil, [], "unknown"), (.advance, nil, [.resultsTabs], nil), (.advance, clip, [], nil)] {
            try T.expect(PhoneWatchChecks.answer(check: check, video: video, signals: signals) == answer,
                "\(check) answered without Laya incorrectly for video \(video?.playing.map(String.init) ?? "nil") and \(signals)")
        }
        try T.expect(PhoneWatchChecks.answer(check: .playback, video: clip, signals: [], advancing: true) == "playing"
            && PhoneWatchChecks.question(id: "consume.playback", check: .playback, evidence: "", video: clip)?.options.map(\.id) == ["playing", "unknown"]
            && PhoneWatchChecks.question(id: "consume.playback", check: .playback, evidence: "", video: paused)?.options.map(\.id) == ["playing", "paused", "unknown"],
            "An advancing playhead did not read as playing, or the toggling pause tap was offered without a structured paused reading")
        try T.expect(PhoneWatchChecks.question(id: "open.player0", check: .popularVideo, evidence: "", video: nil)?.options.map(\.id) == ["ad", "profile", "live", "unknown"]
            && PhoneWatchChecks.question(id: "advance.player", check: .advance, evidence: "", video: nil)?.options.map(\.id) == ["results", "unknown"],
            "A frame without a structured video still offered the player option")
        try T.expect(PhoneWatchChecks.branch(for: "live", check: .popularVideo, evidence: "Heart count: 90K", duration: nil, limit: 60, replay: false, advanceSent: false) == "opened-account-or-ad"
            && PhoneWatchChecks.branch(for: "playing", check: .playback, evidence: "", duration: 90, limit: 120, replay: false, advanceSent: false) == "playing"
            && PhoneWatchChecks.branch(for: "playing", check: .playback, evidence: "", duration: 90, limit: 60, replay: false, advanceSent: false) == "too-long",
            "LIVE rooms or the script's duration limit were not mapped")
        try T.expect(!PhoneTransactionPlan.validWatchQuery("one two three"), "Allowed an overlong query")
        try T.expect(WarmUpScript.Network.allCases.map(PhoneTransactionCompiler.watchTemplateName) == ["tiktok-watch", "instagram-watch", "youtube-watch", "x-watch"],
            "Watch template resource names drifted")
        var tracker = PhoneVideoProgressTracker()
        let date = Date()
        func video(_ progress: Double, _ creator: String = "@one") -> Video {
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
        let captionless = Video(creator: "reel", caption: "", progress: 0.6, durationSeconds: 10, playing: true)
        let audio: Set = ["@reel", "reel · original audio track"]
        _ = tracker.observe(captionless, identity: audio, at: date)
        _ = tracker.observe(.init(creator: "reel", caption: "", progress: 0.95, durationSeconds: 10, playing: true), identity: audio, at: date.addingTimeInterval(4))
        try T.expect(tracker.observe(.init(creator: "reel", caption: "", progress: 0.01, durationSeconds: 10, playing: true), identity: audio,
            at: date.addingTimeInterval(8)).replayCandidate, "A captionless Reel's replay was not recognized from its OCR identity")
        tracker.reset()
        func longVideo(_ progress: Double, duration: Double? = nil) -> Video {
            .init(creator: "@one", caption: "A stable video caption", progress: progress, durationSeconds: duration, playing: true)
        }
        _ = tracker.observe(longVideo(0.1), at: date)
        _ = tracker.observe(longVideo(0.14), at: date.addingTimeInterval(4))
        let estimated = tracker.observe(longVideo(0.18), at: date.addingTimeInterval(8))
        try T.expect((estimated.durationSeconds ?? 0) > 60, "Two consistent progress intervals did not establish an overlong video")
        let readable = tracker.observe(longVideo(0.22, duration: 30), at: date.addingTimeInterval(12))
        try T.expect(readable.durationSeconds == 30, "Estimated duration overrode the readable duration")
        var cursor = WarmUpScriptCursor(script: WarmUpScript(network: .tikTok, activity: .watch, itemLimit: 6, duration: 600, likeLimit: 2, followLimit: 1))
        var engaged: [String] = []
        while !cursor.isComplete {
            switch cursor.step.id {
            case .like, .follow:
                engaged.append("\(cursor.step.id.rawValue)\(cursor.itemsCompleted)")
                try cursor.validate(.tap(0.9, 0.5))
                cursor.didPerform(.tap(0.9, 0.5))
                let tapped = cursor
                do { try tapped.validate(.tap(0.9, 0.5)); throw T.Failure.assertion("An engagement tap was allowed twice") } catch is PhonePromptPlanningError {}
            case .advance: cursor.didPerform(.swipe(.up))
            default: break
            }
            try cursor.finishStep()
        }
        try T.expect(engaged == ["like1", "follow1", "like3"], "Engagement ignored its cadence or daily caps: \(engaged)")
        for script in [WarmUpScript(network: .tikTok, activity: .comment, itemLimit: 1, duration: 300, likeLimit: 1),
                       WarmUpScript(network: .instagram, activity: .watch, itemLimit: 3, duration: 300, followLimit: 1)] {
            do { try script.validate(); throw T.Failure.assertion("Engagement outside TikTok Watch was allowed") } catch is PhonePromptPlanningError {}
        }
    }
}
