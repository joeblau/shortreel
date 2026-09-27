import CoreGraphics
import Foundation

@main
enum PhoneScreenSignalTests {
    enum Failure: Error { case assertion(String) }
    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw Failure.assertion(message) }
    }

    struct Region: Decodable {
        let text: String
        let confidence: Float
        let x: Double, y: Double, width: Double, height: Double
        var textRegion: PhonePlaybackTracker.TextRegion {
            .init(text: text, confidence: confidence, bounds: CGRect(x: x, y: y, width: width, height: height))
        }
    }
    struct Screen: Decodable {
        let id: String
        let matches: [PhoneScreenSignal]
        let misses: [PhoneScreenSignal]
        let regions: [Region]
    }
    struct Fixture: Decodable {
        let network: String?
        let screens: [Screen]
    }

    static func main() throws {
        var checked = 0
        for name in ["tiktok", "instagram", "youtube", "x", "system"] {
            let fixture = try JSONDecoder().decode(Fixture.self,
                from: Data(contentsOf: URL(fileURLWithPath: "Tests/Fixtures/ScreenOCR/\(name).json")))
            let network = fixture.network.flatMap(WarmUpScript.Network.init(rawValue:))
            try expect(fixture.network == nil || network != nil, "\(name): unknown network")
            for screen in fixture.screens {
                let signals = PhoneScreenSignal.matching(screen.regions.map(\.textRegion), network: network)
                for signal in screen.matches {
                    try expect(signals.contains(signal), "\(name).\(screen.id): \(signal.rawValue) did not match")
                }
                for signal in screen.misses {
                    try expect(!signals.contains(signal), "\(name).\(screen.id): \(signal.rawValue) falsely matched")
                }
                checked += 1
            }
        }
        try liveTikTokProfile()
        try iconOnlyTabBars()
        try appNames()
        try itemIdentity()
        print("Screen signal tests passed (\(checked) OCR screens across 4 networks, live TikTok profile, app names, item identity)")
    }

    static func liveTikTokProfile() throws {
        struct Account: Decodable { let handle: String; let regions: [Region] }
        let account = try JSONDecoder().decode(Account.self,
            from: Data(contentsOf: URL(fileURLWithPath: "Tests/Fixtures/AccountOCR/tiktok-empty-profile.json")))
        let signals = PhoneScreenSignal.matching(account.regions.map(\.textRegion), network: .tikTok)
        try expect(account.handle == "toptopnonstop99" && signals.isSuperset(of: [.ownProfile, .tabBar, .profileMarkers]),
            "The live @toptopnonstop99 profile OCR no longer reads as its own profile: \(signals)")
        try expect(signals.isDisjoint(with: [.launchScreen, .adLabel, .dismissControl, .passcode, .liveBadge, .searchFieldText]),
            "The live profile OCR matched an interrupt or search signal: \(signals)")
        let regions = account.regions.map(\.textRegion)
        try expect(!PhoneScreenSignal.ownProfile.matches(regions + [.init(text: "Follow", confidence: 1,
            bounds: CGRect(x: 0.3, y: 0.3, width: 0.2, height: 0.02))], network: .tikTok),
            "A profile with a Follow button read as the own profile")
        try expect(!PhoneScreenSignal.ownProfile.matches(regions.filter { $0.text != "Profile" }, network: .tikTok),
            "A pushed profile without the Profile tab read as the own profile")
    }

    static func iconOnlyTabBars() throws {
        let labels = ["Home", "Search", "Reels", "Profile"].enumerated().map { index, text in
            PhonePlaybackTracker.TextRegion(text: text, confidence: 1, bounds: CGRect(x: 0.1 + 0.2 * Double(index), y: 0.944, width: 0.1, height: 0.012))
        }
        try expect(!PhoneScreenSignal.tabBar.matches(labels, network: .instagram) && !PhoneScreenSignal.tabBar.matches(labels, network: .x),
            "Instagram and X tab bars are icon-only and must never match tabBar")
        try expect(PhoneScreenSignal.tabBar.matches(labels, network: .tikTok), "TikTok tab labels did not match")
    }

    static func appNames() throws {
        for (app, text, named) in [("TikTok", "TikTok Studio", false), ("YouTube", "YouTube Music", false),
                                   ("TikTok", "Home Screen with TikTok Studio and TikTok in the Dock.", true),
                                   ("TikTok", "The TikTok app icon is in the Dock.", true), ("YouTube", "YouTube Kids", false),
                                   ("Instagram", "Instagram", true), ("X", "Xfinity and Excel icons", false),
                                   ("TikTok", "The TikTok app icon is not visible on this Home Screen.", false),
                                   ("TikTok", "No TikTok icon is on this page.", false), ("TikTok", "The TikTok icon isn’t in the Dock.", false),
                                   ("TikTok", "TikTok Studio is in the Dock; the TikTok app is not visible.", false),
                                   ("TikTok", "The Dock holds TikTok, but no Instagram icon.", true)] {
            try expect(PhoneScreenSignal.namesApp(app, in: text) == named, "\(app) in '\(text)' should be \(named)")
        }
        func row(_ text: String, _ confidence: Float = 0.99) -> PhonePlaybackTracker.TextRegion {
            .init(text: text, confidence: confidence, bounds: CGRect(x: 0.2, y: 0.1, width: 0.3, height: 0.02))
        }
        try expect(PhoneScreenSignal.names("X", evidence: "Spotlight search results.", regions: [row("X")])
            && !PhoneScreenSignal.names("TikTok", evidence: "Spotlight search results.", regions: [row("TikTok Studio"), row("TikTok", 0.3)])
            && PhoneScreenSignal.names("YouTube", evidence: "The Dock holds YouTube and Safari.", regions: []),
            "App names were not read from the observer or an exact, confident OCR row")
        let query = [row("TikTok"), .init(text: "Cancel", confidence: 0.99, bounds: CGRect(x: 0.84, y: 0.1, width: 0.1, height: 0.02))]
        try expect(!PhoneScreenSignal.names("TikTok", evidence: "Spotlight search results.", regions: query),
            "The typed Spotlight query beside Cancel counted as the app's result row")
    }

    static func itemIdentity() throws {
        func text(_ rows: [(String, Double)]) -> PhonePlaybackTracker.Observation {
            .init(sourceID: "SR1", capturedAt: Date(), platform: "X", regions: rows.map {
                .init(text: $0.0, confidence: 0.99, bounds: CGRect(x: 0.18, y: $0.1, width: 0.6, height: 0.016))
            })
        }
        let none = PhoneScreenObservation(state: .foregroundApp, appCardsVisible: false, evidence: "X search results")
        let first = PhoneWatchChecks.identity(of: none, text: text([("Jane Doe @janedoe · 2h", 0.16), ("Markets opened higher", 0.19)]), network: .x)
        let second = PhoneWatchChecks.identity(of: none, text: text([("Jane Doe @janedoe · 3h", 0.3), ("A different second post", 0.33)]), network: .x)
        try expect(first.count == 2 && second.count == 2 && first != second, "X posts without video did not get distinct identities")
        let captionless = PhoneScreenObservation(state: .foregroundApp, appCardsVisible: false, evidence: "A Reel",
            video: .init(creator: "creator", caption: "", progress: 0.2, durationSeconds: nil, playing: true))
        let reel = PhonePlaybackTracker.Observation(sourceID: "SR1", capturedAt: Date(), platform: "Instagram", regions: [
            .init(text: "@creator", confidence: 0.99, bounds: CGRect(x: 0.04, y: 0.8, width: 0.2, height: 0.016)),
            .init(text: "creator · Original audio track", confidence: 0.99, bounds: CGRect(x: 0.04, y: 0.86, width: 0.5, height: 0.016))])
        try expect(PhoneWatchChecks.identity(of: captionless, text: reel, network: .instagram).count == 2,
            "A captionless Reel did not fall back to its OCR identity")
    }
}
