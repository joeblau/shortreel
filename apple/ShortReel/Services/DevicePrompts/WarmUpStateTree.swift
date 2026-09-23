import Foundation
import CoreGraphics

struct WarmUpPage: Sendable {
    enum Kind: String, Sendable {
        case feed, ownProfile, searchSuggestions, searchResults, videoPlayer
        case signIn, overlay, unknown
    }
    let kind: Kind
    var controls: [String: CGPoint] = [:]
    var handle: String? = nil

    static func detect(_ observation: PhonePlaybackTracker.Observation) -> Self {
        guard observation.platform == "TikTok" else { return .init(kind: .unknown) }
        let regions = observation.regions.filter { $0.confidence >= 0.9 }
        func text(_ region: PhonePlaybackTracker.TextRegion) -> String {
            region.text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        }
        func find(_ label: String, y: ClosedRange<CGFloat> = 0...1) -> PhonePlaybackTracker.TextRegion? {
            let matches = regions.filter { text($0) == label && y.contains($0.bounds.midY) }
            return matches.count == 1 ? matches.first : nil
        }
        if find("log in to tiktok") != nil,
           find("use phone / email / username") != nil {
            return .init(kind: .signIn)
        }
        if find("allow") != nil && find("don't allow") != nil
            || find("cancel") != nil && (find("report") != nil || find("not interested") != nil)
            || regions.contains(where: { text($0).range(of: #"^[0-9,.]+ comments$"#, options: .regularExpression) != nil })
            || find("share to") != nil && find("copy link") != nil {
            return .init(kind: .overlay)
        }
        var controls: [String: CGPoint] = [:]
        for label in ["home", "profile", "inbox"] {
            if let region = find(label, y: 0.88...1) {
                controls[label] = CGPoint(x: region.bounds.midX, y: region.bounds.midY)
            }
        }
        let handles = regions.filter {
            (0.08...0.4).contains($0.bounds.midY)
                && text($0).range(of: #"^@[a-z0-9_.]{1,40}$"#, options: .regularExpression) != nil
        }
        if find("edit profile", y: 0.15...0.65) != nil,
           find("followers", y: 0.15...0.65) != nil,
           find("following", y: 0.15...0.65) != nil,
           controls["profile"] != nil, handles.count == 1 {
            return .init(kind: .ownProfile, controls: controls, handle: text(handles[0]))
        }
        let hasSearch = find("search", y: 0.04...0.18) != nil
        if hasSearch && ["top", "videos", "users"].allSatisfy({ find($0, y: 0.1...0.25) != nil }) {
            return .init(kind: .searchResults)
        }
        let comment = regions.contains {
            $0.bounds.minY > 0.88 && (text($0).hasPrefix("add comment") || text($0).hasPrefix("add a comment"))
        }
        let rail = regions.filter {
            $0.bounds.minX > 0.82 && (0.35...0.87).contains($0.bounds.midY)
                && text($0).range(of: #"^[0-9][0-9.,]*[km]?$"#, options: .regularExpression) != nil
        }
        let caption = regions.contains {
            $0.bounds.minX < 0.2 && (0.65...0.88).contains($0.bounds.midY) && text($0).count >= 10
        }
        if hasSearch && comment && rail.count >= 3 && caption {
            return .init(kind: .videoPlayer)
        }
        if controls.count == 3, find("for you", y: 0.04...0.2) != nil,
           find("following", y: 0.04...0.2) != nil {
            return .init(kind: .feed, controls: controls)
        }
        if hasSearch, let query = regions.first(where: {
            $0.bounds.minX > 0.1 && $0.bounds.maxX < 0.8 && (0.04...0.15).contains($0.bounds.midY)
                && (1...2).contains(text($0).split(separator: " ").count) && text($0).count >= 3
        }) {
            let suggestions = regions.filter {
                (0.15...0.65).contains($0.bounds.midY) && $0.bounds.minX < 0.25
                    && text($0).hasPrefix(text(query))
            }
            if suggestions.count >= 3 { return .init(kind: .searchSuggestions) }
        }
        return .init(kind: .unknown)
    }
}

struct WarmUpStateTree {
    struct Route {
        let decision: PhoneVisionDecision?
        let context: String
    }
    private var lastRoute = ""
    private var repetitions = 0

    mutating func route(cursor: WarmUpScriptCursor, page: WarmUpPage,
                        playback: PhonePlaybackEvidence?, brief: String) -> Route {
        let node = "\(cursor.step.id.rawValue)/\(page.kind.rawValue)"
        var context = "STATE TREE: \(node). Account gate: \(cursor.index > 0 ? "verified" : "pending"). Advance sent: \(cursor.advanceSent)."
        if cursor.step.id == .account && page.kind == .videoPlayer {
            context += " Leave the player via its observed Back control and navigate to your own Profile. Do not pause, watch, or scroll videos before account verification."
        }
        guard cursor.script.network == .tikTok, cursor.script.activity == .watch else {
            return .init(decision: nil, context: context + " Use platform script.")
        }
        var decision: PhoneVisionDecision?
        if page.kind == .signIn {
            decision = .needsInput("TikTok is asking for sign-in. Check the account before continuing.")
        } else {
            switch (cursor.step.id, page.kind) {
            case (.account, .feed):
                if let point = page.controls["profile"] {
                    decision = .action(.tap(point.x, point.y), reason: "Open the visible Profile tab to verify the account.")
                }
            case (.account, .ownProfile):
                if let expected = Self.expectedHandle(brief), let actual = page.handle {
                    decision = expected == actual
                        ? .finished("Own profile shows the expected handle \(actual).")
                        : .needsInput("The signed-in handle \(actual) does not match \(expected).")
                }
            case (.search, .ownProfile):
                if let point = page.controls["home"] {
                    decision = .action(.tap(point.x, point.y), reason: "Return to the feed using the visible Home tab.")
                }
            case (.suggestion, .searchResults):
                decision = .finished("Search results are already visible; proceed to select a qualifying video.")
            case (.consume, .videoPlayer):
                if let total = playback?.durationSeconds,
                   let limit = cursor.script.maximumVideoDurationSeconds, total > limit {
                    decision = .action(.swipe(.up), reason: "Visible duration \(total)s exceeds \(limit)s; skip without counting.")
                } else if playback?.isAdvancing == true {
                    decision = .wait(seconds: 1, reason: "The same video's timer is advancing; observe playback.")
                }
            case (.advance, .videoPlayer) where !cursor.advanceSent:
                decision = .action(.swipe(.up), reason: "Viewing is verified. Swipe once to the next video.")
            default: break
            }
        }
        guard let decision else {
            lastRoute = ""; repetitions = 0
            return .init(decision: nil, context: context + " Inspect this page; return one decision for the current step.")
        }
        let key = node + String(describing: decision)
        if key == lastRoute { repetitions += 1 } else { lastRoute = key; repetitions = 1 }
        guard repetitions <= 2 else {
            repetitions = 0
            return .init(decision: nil, context: context + " Local route repeated twice; inspect the transition before another input.")
        }
        return .init(decision: decision, context: context + " Local route.")
    }

    static func expectedHandle(_ brief: String) -> String? {
        guard let line = brief.components(separatedBy: .newlines).first(where: { $0.hasPrefix("Account check:") }),
              let range = line.range(of: #"Verify exactly @[a-zA-Z0-9_.]{1,40},"#, options: .regularExpression) else { return nil }
        return String(line[range].dropFirst("Verify exactly ".count).dropLast()).lowercased()
    }
}
