import CoreGraphics
import Foundation

@main
enum WarmUpAccountClassifierTests {
    enum Failure: Error { case assertion(String) }
    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw Failure.assertion(message) }
    }

    struct Fixture: Decodable {
        struct Region: Decodable {
            let text: String
            let confidence: Float
            let x: Double, y: Double, width: Double, height: Double
        }
        let platform: String
        let handle: String
        let outcome: String
        let ownProfile: Bool
        let regions: [Region]
        let visualEvidence: String?

        var textRegions: [PhoneSubmissionGuard.TextRegion] {
            regions.map {
                PhoneSubmissionGuard.TextRegion(text: $0.text, confidence: $0.confidence,
                    bounds: CGRect(x: $0.x, y: $0.y, width: $0.width, height: $0.height))
            }
        }
    }

    final class StubScorer: SemanticIfScoring, @unchecked Sendable {
        let winner: String
        let winnerP: Double
        private(set) var rows: [SemanticIfRow] = []

        init(winner: String, winnerP: Double = 0.7) {
            self.winner = winner
            self.winnerP = winnerP
        }

        func score(_ row: SemanticIfRow) async throws -> SemanticIfResult {
            rows.append(row)
            let losers = row.options.map(\.id).filter { $0 != winner }
            var probabilities = [winner: winnerP]
            for loser in losers { probabilities[loser] = (1 - winnerP) / Double(losers.count) }
            let runnerUp = probabilities.values.sorted(by: >).dropFirst().first ?? 0
            return SemanticIfResult(score: SemanticIfScore(
                rowID: row.id, probabilities: probabilities, argmaxOptionID: winner,
                margin: winnerP - runnerUp, optionLogits: [], inputTokens: 0,
                forwardSeconds: 0, totalSeconds: 0, promptHash: "stub-\(winner)", peakMemoryBytes: 0))
        }
    }

    static func main() async throws {
        try await goldenFixtures()
        try await belowMarginIsUnreadable()
        try rowContract()
        try await unknownOptionThrows()
        try observedHandleNormalization()
        try await exactIdentityGuards()
        try await emptyProfileUsesVisualEvidence()
        try await nonProfileHandlesNeverMismatch()
        try await networkHandleLayouts()
        print("Warm-up account classifier tests passed (including the reported empty TikTok profile)")
    }

    static func goldenFixtures() async throws {
        let names = ["tiktok", "instagram", "x", "youtube"]
            .flatMap { platform in ["matches", "mismatch", "signed-out", "unreadable"].map { "\(platform)-\($0)" } }
            + ["tiktok-empty-profile", "instagram-own-no-at", "youtube-hyphen"] + nonProfileFixtures
        for name in names {
            let fixture = try loadFixture(name)
            let signal = PhoneScreenSignal.ownProfile.matches(fixture.textRegions.map {
                .init(text: $0.text, confidence: $0.confidence, bounds: $0.bounds)
            }, network: WarmUpScript.Network(rawValue: fixture.platform))
            try expect(signal == fixture.ownProfile, "\(name): ownProfile signal \(signal) contradicts the fixture label")
            let surface = fixture.outcome == "signed-out" ? "signed-out" : "profile"
            let scorer = StubScorer(winner: surface)
            let decision = try await WarmUpAccountClassifier.classify(regions: fixture.textRegions,
                platform: fixture.platform, accountLocation: "test account location",
                handle: fixture.handle, scorer: scorer)
            try expect(decision.outcome.rawValue == fixture.outcome, "\(name): verdict \(decision.outcome) != \(fixture.outcome)")
            if fixture.ownProfile {
                try expect(scorer.rows.isEmpty && decision.promptHash.isEmpty && decision.margin > decision.threshold,
                    "\(name): own-profile OCR still asked Laya for the surface")
                continue
            }
            try expect(decision.promptHash == "stub-\(surface)", "\(name): prompt hash not journaled")
            try expect(decision.probabilities.count == 3 && decision.margin > decision.threshold,
                "\(name): readout diagnostics missing")
            let row = try scorer.rows.first ?? { throw Failure.assertion("\(name): scorer never called") }()
            try expect(row.id == "warmup.account.\(fixture.platform.lowercased())", "\(name): row id drifted")
            try expect(row.question == LayaAccountPrompt.question, "\(name): question drifted")
            try expect(row.options.map(\.id) == LayaAccountPrompt.options.map(\.id), "\(name): option order drifted")
            guard case .string(let state) = row.state else { throw Failure.assertion("Malformed state") }
            let texts = state.components(separatedBy: "\n")
            let expectedOrder = fixture.regions
                .sorted { ($0.y, $0.x) < ($1.y, $1.x) }
                .map(\.text)
            try expect(texts == expectedOrder, "\(name): OCR regions lost or out of order")
            if fixture.outcome == "mismatch" {
                try expect(decision.evidence.contains("@jane.doe88") && decision.evidence.contains("@\(fixture.handle)"),
                    "\(name): mismatch evidence must name both handles")
            }
        }
    }

    static func belowMarginIsUnreadable() async throws {
        let fixture = try loadFixture("tiktok-matches")
        let scorer = StubScorer(winner: "profile", winnerP: 0.34)
        let decision = try await WarmUpAccountClassifier.classify(regions: fixture.textRegions.filter { $0.text != "Profile" },
            platform: fixture.platform, accountLocation: "test account location",
            handle: fixture.handle, scorer: scorer)
        try expect(decision.outcome == .unreadable, "Below-margin score did not route to the unreadable recovery")
        try expect(decision.margin < decision.threshold, "Margin diagnostics lost")
    }

    static func rowContract() throws {
        let row = try WarmUpAccountClassifier.row(platform: "TikTok",
            accountLocation: "Tap the Profile tab.", handle: "janedoe", ocrText: ["@janedoe"])
        try SemanticIfPrompt.validate(row.decision)
        try expect(row.options.count <= 16, "More than 16 options")
        try expect(row.options == LayaAccountPrompt.options, "Screen classification options drifted")
        do {
            _ = try WarmUpAccountClassifier.options(failureModes: [])
            throw Failure.assertion("Missing contract failure modes built a row anyway")
        } catch WarmUpAccountClassifier.ClassifierError.missingFailureMode { }
    }

    static func unknownOptionThrows() async throws {
        let fixture = try loadFixture("tiktok-matches")
        let scorer = StubScorer(winner: "bogus")
        do {
            _ = try await WarmUpAccountClassifier.classify(regions: fixture.textRegions.filter { $0.text != "Profile" },
                platform: fixture.platform, accountLocation: "test account location",
                handle: fixture.handle, scorer: scorer)
            throw Failure.assertion("An undeclared scorer option became a verdict")
        } catch WarmUpAccountClassifier.ClassifierError.unknownOption(let id) {
            try expect(id == "bogus", "Wrong unknown option id")
        }
    }

    static func observedHandleNormalization() throws {
        let regions = [
            PhoneSubmissionGuard.TextRegion(text: "Jane Doe", confidence: 0.9, bounds: CGRect(x: 0.3, y: 0.1, width: 0.2, height: 0.03)),
            PhoneSubmissionGuard.TextRegion(text: "  @Jane.Doe88 ", confidence: 0.9, bounds: CGRect(x: 0.3, y: 0.17, width: 0.2, height: 0.03)),
        ]
        try expect(WarmUpAccountClassifier.observedHandle(in: regions) == "jane.doe88", "Observed handle not normalized")
        try expect(WarmUpAccountClassifier.observedHandle(in: Array(regions.prefix(1))) == nil, "Handle invented without an @ token")
    }

    static func exactIdentityGuards() async throws {
        func region(_ text: String, _ confidence: Float = 0.95, y: Double = 0) -> PhoneSubmissionGuard.TextRegion {
            .init(text: text, confidence: confidence, bounds: CGRect(x: 0, y: y, width: 1, height: 0.03))
        }
        let ownProfile = [region("Following", y: 0.3), region("Followers", y: 0.3), region("Likes", y: 0.3), region("Profile", y: 0.94)]
        for (regions, surface, expected) in [
            ([region("@JANEDOE")], "profile", WarmUpAccountDecision.Outcome.matches),
            ([region("@janedoe", 0.59)], "profile", .unreadable),
            ([region("@janedoe"), region("@someoneelse")], "profile", .unreadable),
            ([region("@janedoe")], "signed-out", .unreadable),
            ([region("@janedoe"), region("Log in")], "signed-out", .signedOut),
            ([region("@janedoe"), region("Log in")], "profile", .signedOut),
            ([region("@janedoe")], "unknown", .unreadable),
            ([region("@janedoe2")], "profile", .unreadable),
            ([region("@janedoe2")] + ownProfile, "profile", .mismatch),
            ([region("@janedoe2", 0.7)] + ownProfile, "profile", .unreadable),
            ([region("@janedoe2", y: 0.8)] + ownProfile, "profile", .unreadable),
            ([region("@JANEDOE")] + ownProfile, "profile", .matches),
        ] {
            let result = try await WarmUpAccountClassifier.classify(regions: regions,
                platform: "TikTok", accountLocation: "profile", handle: "janedoe", scorer: StubScorer(winner: surface))
            try expect(result.outcome == expected, "Exact identity guard failed: \(result.outcome) != \(expected)")
        }
        try expect(LayaAccountPrompt.handles(in: "mail@janedoe.com").isEmpty, "Email address became a handle")
        try expect(LayaAccountPrompt.handles(in: "@joe-blau • View channel") == ["joe-blau"], "Hyphenated handle was truncated")
    }

    static let nonProfileFixtures = ["tiktok-feed-mention", "instagram-feed-mention", "youtube-shorts-creator", "x-timeline-one-handle"]

    static func nonProfileHandlesNeverMismatch() async throws {
        for name in nonProfileFixtures {
            let fixture = try loadFixture(name)
            for surface in ["profile", "unknown", "signed-out"] {
                let result = try await WarmUpAccountClassifier.classify(regions: fixture.textRegions, platform: fixture.platform,
                    accountLocation: "profile", handle: fixture.handle, scorer: StubScorer(winner: surface, winnerP: 0.99))
                try expect(result.outcome == .unreadable, "\(name) as \(surface): a feed or creator handle became \(result.outcome)")
            }
        }
    }

    static func networkHandleLayouts() async throws {
        let instagram = try loadFixture("instagram-own-no-at")
        try expect(WarmUpAccountClassifier.readableHandles(in: instagram.textRegions, platform: "Instagram") == ["janedoe"],
            "Instagram top-bar username was not read without an @ token")
        try expect(WarmUpAccountClassifier.readableHandles(in: instagram.textRegions, platform: "TikTok").isEmpty,
            "A bare name was read as a handle outside Instagram")
        let youtube = try loadFixture("youtube-hyphen")
        let joe = try await WarmUpAccountClassifier.classify(regions: youtube.textRegions, platform: youtube.platform,
            accountLocation: "You tab", handle: "joe", scorer: StubScorer(winner: "profile"))
        try expect(joe.outcome == .mismatch && joe.evidence.contains("@joe-blau"), "@joe-blau matched the prefix handle @joe")
        let live = try loadFixture("tiktok-empty-profile")
        for handle in ["toptopnonstop99", "@TopTopNonStop99"] {
            for surface in ["profile", "signed-out", "unknown"] {
                let result = try await WarmUpAccountClassifier.classify(regions: live.textRegions, platform: live.platform,
                    accountLocation: "Profile tab", handle: handle, scorer: StubScorer(winner: surface, winnerP: 0.99))
                try expect(result.outcome == .matches, "The live TikTok profile OCR no longer matches @toptopnonstop99 when Laya reads \(surface)")
            }
        }
    }

    static func emptyProfileUsesVisualEvidence() async throws {
        let fixture = try loadFixture("tiktok-empty-profile")
        let scorer = StubScorer(winner: "profile")
        let observation = PhoneScreenObservation(state: .foregroundApp, appCardsVisible: false,
            evidence: "A profile with an Upload prompt and zero posts.", checkEvidence: fixture.visualEvidence)
        let result = try await WarmUpAccountClassifier.classify(regions: fixture.textRegions.filter { $0.text != "Profile" },
            platform: fixture.platform, accountLocation: "own profile header", handle: "@" + fixture.handle,
            scorer: scorer, observation: observation)
        try expect(result.outcome == .matches, "Empty profile did not pass the exact handle check")
        try expect(scorer.rows.first?.state == .string(fixture.visualEvidence!), "Account classification discarded the current visual evidence")
        try expect(!result.evidence.contains("@@"), "Account messages duplicated the @ prefix")
        for handle in ["someoneelse", "toptopnonstop9"] {
            let mismatch = try await WarmUpAccountClassifier.classify(regions: fixture.textRegions,
                platform: fixture.platform, accountLocation: "own profile header", handle: handle,
                scorer: scorer, observation: observation)
            try expect(mismatch.outcome == .mismatch, "Visual profile evidence bypassed the exact handle comparison")
        }
        let missing = try await WarmUpAccountClassifier.classify(regions: [], platform: fixture.platform,
            accountLocation: "own profile header", handle: fixture.handle, scorer: scorer, observation: observation)
        try expect(missing.outcome == .unreadable, "A visual description invented the OCR handle")
    }

    static func loadFixture(_ name: String) throws -> Fixture {
        let url = URL(fileURLWithPath: "Tests/Fixtures/AccountOCR/\(name).json")
        return try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
    }
}
