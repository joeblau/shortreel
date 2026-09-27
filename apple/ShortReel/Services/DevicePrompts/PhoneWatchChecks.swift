import Foundation

enum PhoneWatchChecks {
    static func question(id: String, check: PhoneTransactionPlan.State.Check, evidence: String,
                         video: PhoneScreenObservation.Video?) -> PhoneTransactionQuestion? {
        var options: [(String, String)]
        switch check {
        case .query, .like, .follow: return nil
        case .popularVideo:
            options = [("player", "A full-screen video player."), ("ad", "An advertisement."),
                       ("profile", "A social media profile page."), ("live", "A LIVE stream with viewers and gifts."),
                       ("unknown", "A different or unreadable screen.")]
        case .playback:
            options = [("playing", "A playing video."), ("paused", "A paused video with a play button."),
                       ("unknown", "A screen without a readable video player.")]
        case .advance:
            options = [("player", "A full-screen video player."), ("results", "A two-column grid of video thumbnails."),
                       ("unknown", "A different or unreadable screen.")]
        }
        if video == nil { options.removeAll { $0.0 == "player" } }
        if check == .playback, video?.playing != false { options.removeAll { $0.0 == "paused" } }
        return .init(id: id, evidence: evidence,
            options: options.map { .init(id: $0.0, description: $0.1) }, question: "What is visible on the screen?")
    }

    /// The option a check takes from the observer's structured video fields or OCR signals, without Laya.
    static func answer(check: PhoneTransactionPlan.State.Check, video: PhoneScreenObservation.Video?,
                       signals: Set<PhoneScreenSignal>, advancing: Bool = false) -> String? {
        switch check {
        case .popularVideo: signals.contains(.adLabel) ? "ad" : nil
        case .playback: video == nil ? "unknown" : video?.playing.map { $0 ? "playing" : "paused" } ?? (advancing ? "playing" : nil)
        case .advance: video == nil && !signals.contains(.resultsTabs) ? "unknown" : nil
        case .query, .like, .follow: nil
        }
    }

    static func branch(for selected: String?, check: PhoneTransactionPlan.State.Check,
                       evidence: String, duration: Int?, limit: Int?, replay: Bool, advanceSent: Bool) -> String? {
        switch check {
        case .query, .like, .follow: return selected
        case .popularVideo:
            if ["ad", "profile", "live"].contains(selected) { return "opened-account-or-ad" }
            guard selected == "player" else { return nil }
            guard let count = heartCount(in: evidence) else { return "threshold-unreadable" }
            return count > 10_000 ? "qualified" : "below"
        case .playback:
            guard selected == "playing" || selected == "paused" else { return nil }
            if let duration, let limit, duration > limit { return "too-long" }
            if selected == "playing", replay { return "complete" }
            return selected
        case .advance:
            if selected == "results" { return "results-grid" }
            guard selected == "player" else { return nil }
            return advanceSent ? "alreadySent" : "ready"
        }
    }

    static func heartCount(in evidence: String) -> Double? {
        let pattern = #"(?i)\bheart\s+count\s*:\s*([0-9][0-9,]*(?:\.[0-9]+)?\s*[KM]?)\b"#
        guard let match = evidence.range(of: pattern, options: .regularExpression) else { return nil }
        let token = evidence[match].split(separator: ":", maxSplits: 1)[1]
            .replacingOccurrences(of: ",", with: "").filter { !$0.isWhitespace }.uppercased()
        let multiplier: Double = token.hasSuffix("M") ? 1_000_000 : token.hasSuffix("K") ? 1_000 : 1
        let number = token.filter { $0.isNumber || $0 == "." }
        guard let value = Double(number), value.isFinite else { return nil }
        return value * multiplier
    }

    /// The on-screen keyboard's letter keys, read by local OCR in the lower half of the screen.
    static func keyboardVisible(in text: PhonePlaybackTracker.Observation) -> Bool {
        let keys = Set(text.regions.filter { $0.confidence >= 0.5 && $0.bounds.minY >= 0.5 }
            .flatMap { $0.text.uppercased().split(whereSeparator: \.isWhitespace) }
            .filter { $0.count == 1 && "QWERTYUIOPASDFGHJKLZXCVBNM".contains($0) })
        return keys.count >= 8
    }

    /// The typed query in the search field band. OCR reads the field's magnifier as a leading "Q" ("Q swing trading") and may read
    /// its clear button as a trailing x; suggestion rows below the field never count.
    static func queryVisible(_ query: String, in text: PhonePlaybackTracker.Observation) -> Bool {
        let expected = query.lowercased()
        return text.regions.contains { region in
            guard region.confidence >= 0.6, region.bounds.minY < 0.12 else { return false }
            var field = region.text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
            if field != expected, let glyph = field.range(of: #"^[q⌕🔍]\s+"#, options: .regularExpression) { field.removeSubrange(glyph) }
            if field != expected, let clear = field.range(of: #"\s+[x×⊗ⓧ]$"#, options: .regularExpression) { field.removeSubrange(clear) }
            return field == expected
        }
    }

    /// Whether two readings are the same item. Observers transcribe one caption differently across frames (emoji, a dropped word,
    /// truncation), so creator-and-caption identities match on the same creator and mostly shared caption words; others must be equal.
    static func sameItem(_ lhs: Set<String>, _ rhs: Set<String>) -> Bool {
        if lhs == rhs { return true }
        func field(_ key: String, _ identity: Set<String>) -> String? {
            identity.first { $0.hasPrefix(key) }.map { String($0.dropFirst(key.count)) }
        }
        func words(_ text: String) -> [String] {
            text.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
        }
        guard lhs.count == 2, rhs.count == 2,
              let one = field("creator:", lhs), let two = field("creator:", rhs), words(one) == words(two), !words(one).isEmpty,
              let first = field("caption:", lhs).map(words), let second = field("caption:", rhs).map(words),
              !first.isEmpty, !second.isEmpty else { return false }
        guard first.filter({ $0.allSatisfy(\.isNumber) }) == second.filter({ $0.allSatisfy(\.isNumber) }) else { return false }
        let shorter = first.count <= second.count ? first : second, longer = first.count <= second.count ? second : first
        if shorter.count >= 4, Array(longer.prefix(shorter.count - 1)) == Array(shorter.dropLast()),
           let last = shorter.last, longer[shorter.count - 1].hasPrefix(last) { return true }
        let a = Set(first), b = Set(second)
        return Double(a.intersection(b).count) / Double(a.union(b).count) >= 0.6
    }

    static let tabNames = ["Top", "Videos", "Users", "Photos", "Sounds", "Shop", "LIVE", "Places", "Hashtags", "For you", "Accounts",
                           "Audio", "Tags", "Reels", "Latest", "People", "Media", "Lists", "All", "Shorts", "Unwatched"]

    /// Whether the observer states that this tab, and no other, is the selected one. OCR cannot see a tab underline, and a tap on
    /// the neighboring tab (TikTok LIVE for Videos) otherwise passes the results-tab postcondition. Tab names are matched as written
    /// ("Videos", not "live videos highlighted").
    static func selectsTab(_ tab: String, in texts: [String]) -> Bool {
        func stated(_ name: String, _ text: String) -> Bool {
            let name = NSRegularExpression.escapedPattern(for: name), states = "(?i:selected|underlined|highlighted|active)"
            return [#"(?<![\p{L}])"# + name + #"(?![\p{L}])(?:\s+(?i:tab))?(?:\s+(?i:is|appears))?(?:\s+(?i:now|currently))?(?:\s+(?i:as))?\s+"# + states,
                    states + #"\s+(?:(?i:the)\s+)?"# + name + #"\s+(?i:tab)\b"#,
                    #"(?<![\p{L}])"# + name + #"(?![\p{L}])\s+(?i:is the)\s+(?i:selected|active)\s+(?i:tab)"#]
                .contains { text.range(of: $0, options: .regularExpression) != nil }
        }
        return texts.contains { text in
            stated(tab, text) && text.range(of: #"(?i)\b(not|isn't|instead)\b"#, options: .regularExpression) == nil
                && !tabNames.contains { $0 != tab && stated($0, text) }
        }
    }

    /// Whether the observer reports the page still loading.
    static func loading(_ texts: [String]) -> Bool {
        texts.contains { $0.range(of: #"(?i)\b(loading (indicator|spinner|dots|animation)|spinner|(is|still) loading|buffering)\b"#,
            options: .regularExpression) != nil }
    }

    /// A dismiss tap lands only on a dismiss label, or on an unlabeled icon (a close X) away from any control that acts.
    static func safeDismissTap(x: Double, y: Double, regions: [PhonePlaybackTracker.TextRegion]) -> Bool {
        let point = CGPoint(x: x, y: y)
        let readable = regions.filter { $0.confidence >= 0.5 }
        func text(_ region: PhonePlaybackTracker.TextRegion) -> String {
            region.text.lowercased().replacingOccurrences(of: "’", with: "'").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let safe = #"^(x|×|✕|close|cancel|not now|don't allow|ask app not to track|maybe later|no thanks|skip|skip for now|dismiss|got it)$"#
        let risky = #"\b(follow|subscribe|allow|ok|save|continue|turn on|turn off|buy|purchase|recharge|join|send|share|repost|report|block|delete|discard|not interested|ignore|trust|sign up|log in|install|download|upgrade)\b"#
        let touched = readable.filter { $0.bounds.insetBy(dx: -0.02, dy: -0.02).contains(point) }
        if !touched.isEmpty { return touched.allSatisfy { text($0).range(of: safe, options: .regularExpression) != nil } }
        return !readable.contains { region in
            region.bounds.insetBy(dx: -0.05, dy: -0.05).contains(point)
                && text(region).range(of: risky, options: .regularExpression) != nil && text(region).range(of: safe, options: .regularExpression) == nil
        }
    }

    /// Whether a tap point sits on or beside a Follow, Subscribe, or Join control.
    static func nearFollow(x: Double, y: Double, regions: [PhonePlaybackTracker.TextRegion]) -> Bool {
        regions.contains { region in
            region.confidence >= 0.5 && region.bounds.insetBy(dx: -0.03, dy: -0.03).contains(CGPoint(x: x, y: y))
                && region.text.trimmingCharacters(in: .whitespacesAndNewlines)
                    .range(of: #"(?i)^(\+ ?)?(follow|follow back|subscribe|subscribed|join)$"#, options: .regularExpression) != nil
        }
    }

    /// The current item's identity: the observer's video identity, else the OCR caption or X post.
    static func identity(of observation: PhoneScreenObservation, text: PhonePlaybackTracker.Observation,
                         network: WarmUpScript.Network?) -> Set<String> {
        if let video = observation.video?.identity, !video.isEmpty { return video }
        return network == .x ? postIdentity(in: text) : identity(in: text)
    }

    static func postIdentity(in text: PhonePlaybackTracker.Observation) -> Set<String> {
        let rows = text.regions.filter { $0.confidence >= 0.85 && (0.12..<0.6).contains($0.bounds.minY) }
            .sorted { ($0.bounds.minY, $0.bounds.minX) < ($1.bounds.minY, $1.bounds.minX) }
        guard let author = rows.first(where: { !LayaAccountPrompt.handles(in: $0.text).isEmpty }),
              let handle = LayaAccountPrompt.handles(in: author.text).first,
              let line = rows.first(where: { $0.bounds.minY >= author.bounds.maxY - 0.005
                  && LayaAccountPrompt.handles(in: $0.text).isEmpty && $0.text.filter(\.isLetter).count >= 2 }) else { return [] }
        return ["handle:" + handle.lowercased(),
                "text:" + line.text.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")]
    }

    static func identity(in text: PhonePlaybackTracker.Observation) -> Set<String> {
        Set(text.regions.compactMap { region in
            guard region.confidence >= 0.85, region.bounds.minX < 0.55,
                  region.bounds.minY >= 0.5, region.bounds.maxY < 0.9 else { return nil }
            let value = region.text.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
            guard !["search", "for you", "following", "add comment", "sponsored"].contains(where: value.contains),
                  value.hasPrefix("@") || value.split(separator: " ").count >= 3 else { return nil }
            return value
        })
    }
}

/// Completion by continuous viewing of one video, for players that show no timer or progress bar.
struct PhoneWatchDwell {
    private var identity: Set<String> = []
    private var since: Date?

    mutating func reset() { identity = []; since = nil }

    /// True once the same video has played continuously for its readable duration, or past `limit` when unreadable.
    mutating func observe(identity current: Set<String>, playing: Bool?, at date: Date, duration: Int?, limit: Int) -> Bool {
        guard current.count >= 2 else { reset(); return false }
        guard PhoneWatchChecks.sameItem(current, identity), let since, playing != false else {
            identity = current
            since = date
            return false
        }
        let required = Double(duration.map { min($0, limit) } ?? limit) + 2
        return date.timeIntervalSince(since) >= required
    }
}

struct PhoneVideoProgressTracker {
    private var previous: (video: PhoneScreenObservation.Video, identity: Set<String>, date: Date)?
    private var advanced = false
    private var estimates: [Double] = []
    private var rate: Double?
    private var origin: (progress: Double, date: Date)?

    mutating func reset() { previous = nil; advanced = false; estimates = []; rate = nil; origin = nil }

    /// `identity` defaults to the observer's creator and caption; captionless items pass their OCR identity.
    mutating func observe(_ video: PhoneScreenObservation.Video?, identity: Set<String>? = nil, at date: Date) -> PhonePlaybackEvidence {
        let identity = identity ?? video?.identity ?? []
        guard let video, video.isValid, identity.count >= 2 else {
            reset()
            return .init(summary: "No readable video identity and playhead position.", replayCandidate: false)
        }
        // An unreadable playhead on the same item (often at the loop point) keeps its history so the replay is still seen.
        guard let progress = video.progress else {
            if let previous, !PhoneWatchChecks.sameItem(previous.identity, identity) { reset() }
            return .init(summary: "No readable playhead position.", replayCandidate: false,
                durationSeconds: video.durationSeconds.map { Int($0.rounded()) })
        }
        let readableDuration = video.durationSeconds.map { Int($0.rounded()) }
        defer { previous = (video, identity, date) }
        guard let previous, PhoneWatchChecks.sameItem(previous.identity, identity),
              let before = previous.video.progress, date > previous.date,
              date.timeIntervalSince(previous.date) <= 30 else {
            advanced = false; estimates = []; rate = nil; origin = (progress, date)
            return .init(summary: "Visible playhead at \(Int(progress * 100))%; observing continuity.",
                replayCandidate: false, durationSeconds: readableDuration)
        }
        if video.playing == false || previous.video.playing == false {
            advanced = false; estimates = []; rate = nil; origin = nil
            return .init(summary: "Playback is paused; no completion established.", replayCandidate: false, durationSeconds: readableDuration)
        }
        let seconds = date.timeIntervalSince(previous.date)
        // Observations arrive seconds apart, so the last reading before a loop can be well short of the end:
        // the playhead's own rate must have carried it past the end before it reset near the beginning.
        if advanced, progress <= 0.2, before - progress >= 0.5,
           before >= 0.9 || rate.map({ before + $0 * seconds >= 0.95 }) == true {
            advanced = false; rate = nil; origin = nil
            return .init(summary: "The same creator and caption advanced to the end, then the playhead reset near the beginning.",
                replayCandidate: true, durationSeconds: readableDuration)
        }
        let delta = progress - before
        if delta > 0.01 {
            let plausible = video.durationSeconds.map { delta * $0 <= seconds * 2 + 2 } ?? (delta <= 0.5)
            advanced = plausible
            rate = plausible ? delta / seconds : nil
            if plausible, seconds >= 3 {
                estimates.append(seconds / delta)
                estimates = Array(estimates.suffix(2))
            } else { estimates = [] }
        } else if delta < 0 { advanced = false; estimates = []; rate = nil }
        if delta < -0.1 || (abs(delta) < 0.005 && seconds >= 3) || origin == nil { origin = (progress, date) }
        var duration = readableDuration
        if duration == nil, estimates.count == 2, let low = estimates.min(), let high = estimates.max(),
           low > 60, high / low <= 1.25 {
            duration = Int(low.rounded(.down))
        }
        // Observer playheads jitter by a few percent, so pairwise rates rarely agree on long videos; the whole continuous span does.
        if duration == nil, let origin, date.timeIntervalSince(origin.date) >= 20, progress - origin.progress >= 0.03 {
            let whole = date.timeIntervalSince(origin.date) / (progress - origin.progress)
            if whole > 90 { duration = Int(whole.rounded(.down)) }
        }
        return .init(summary: "Visible playhead at \(Int(progress * 100))%; completion not established.",
            replayCandidate: false, durationSeconds: duration, isAdvancing: delta > 0.01 && advanced)
    }
}

/// Deterministic screen facts read from local OCR, for gating branches that Laya's lexical scoring cannot separate.
enum PhoneScreenSignal: String, Codable, CaseIterable, Sendable {
    case tabBar, dismissControl, passcode, adLabel, liveBadge, searchFieldText, resultsTabs,
         profileMarkers, ownProfile, inlineTimer, noResults, launchScreen, appStoreResult, replyBar, feedPost

    static func matching(_ regions: [PhonePlaybackTracker.TextRegion], network: WarmUpScript.Network?) -> Set<Self> {
        Set(allCases.filter { $0.matches(regions, network: network) })
    }

    func matches(_ regions: [PhonePlaybackTracker.TextRegion], network: WarmUpScript.Network?) -> Bool {
        let lines = regions.filter { $0.confidence >= 0.6 }.map { (label: Self.label($0.text), bounds: $0.bounds) }
            .filter { !$0.label.isEmpty }
        let networks = network.map { [$0] } ?? WarmUpScript.Network.allCases
        func has(_ pattern: String, _ place: (CGRect) -> Bool = { _ in true }) -> Bool {
            lines.contains { place($0.bounds) && $0.label.range(of: pattern, options: .regularExpression) != nil }
        }
        func labels(_ names: Set<String>, _ place: (CGRect) -> Bool = { _ in true }) -> Set<String> {
            Set(lines.filter { place($0.bounds) && names.contains($0.label) }.map(\.label))
        }
        let authors = network == .x ? lines.filter { (0.1..<0.95).contains($0.bounds.minY)
            && $0.label.range(of: #"(^|\s)@[a-z0-9_]{1,15}( ?[·•].*)?$"#, options: .regularExpression) != nil }
            .map(\.bounds.minY).sorted() : []
        func topPost(_ bounds: CGRect) -> Bool {
            guard let first = authors.first else { return true }
            return bounds.minY >= first - 0.01 && bounds.minY < (authors.dropFirst().first ?? 1.005) - 0.005
        }
        switch self {
        case .tabBar:
            let bottom = Set(regions.filter { $0.confidence >= 0.5 && $0.bounds.minY >= 0.85 }.map { Self.label($0.text) })
            let header = labels(["for you", "following", "explore"]) { $0.minY < 0.12 }
            return networks.contains { bottom.intersection(Self.tabs[$0] ?? []).count >= 2 }
                || (networks.contains(.tikTok) && header.contains("for you") && header.count >= 2
                    && !Self.liveBadge.matches(regions, network: network))
        case .dismissControl:
            return has(#"^(not now|don't allow|ask app not to track|maybe later|no thanks|skip|skip for now|dismiss|close|got it)$"#) { $0.minY >= 0.15 }
        case .passcode:
            return has(#"^(enter passcode|face id|touch id|swipe up to (open|unlock))$"#)
                || Set(lines.filter { $0.bounds.minY >= 0.3 && $0.label.range(of: #"^[0-9]$"#, options: .regularExpression) != nil }.map(\.label)).count >= 6
        case .adLabel:
            return has(#"^(sponsored|promoted|ad|paid partnership( with .+)?)$|^ad\s*[·•]|^(shop now|learn more|install|download|visit advertiser|get offer|order now)$"#, topPost)
        case .liveBadge:
            return has(#"^(live|live now|tap to watch live)$"#) { $0.minY >= 0.15 }
                && has(#"^[0-9][0-9.,]*[km]?( viewers?| watching)?$"#)
                && !Self.resultsTabs.matches(regions, network: network)
        case .searchFieldText:
            let excluded = networks.reduce(into: Set(["search", "cancel"])) { $0.formUnion(Self.placeholders[$1] ?? []) }
            return lines.contains { line in
                (0.045..<0.12).contains(line.bounds.minY) && !excluded.contains(line.label)
                    && line.label.filter { $0.isLetter || $0.isNumber }.count >= 2
                    && line.label.range(of: #"^[0-9]{1,2}:[0-9]{2}|^[0-9]{1,3}%$"#, options: .regularExpression) == nil
            }
        case .resultsTabs:
            let tabs = lines.filter { $0.bounds.minY < 0.3 }
            return networks.contains { network in
                guard let names = Self.results[network] else { return false }
                return tabs.contains { row in
                    let found = Set(tabs.filter { abs($0.bounds.midY - row.bounds.midY) <= 0.02 && names.all.contains($0.label) }.map(\.label))
                    return found.count >= 2 && !found.isDisjoint(with: names.anchors)
                }
            }
        case .profileMarkers:
            return has(#"\bfollowers\b"#) { $0.minY < 0.5 } && has(#"\bfollowing\b"#) { $0.minY < 0.5 }
        case .ownProfile:
            return networks.contains { network in
                switch network {
                case .tikTok:
                    ["following", "followers", "likes"].allSatisfy { has(#"^([0-9][0-9.,]*[km]? )?"# + $0 + "$") { $0.minY < 0.5 } }
                        && has("^profile$") { $0.minY >= 0.85 } && !has("^(follow|follow back|message)$")
                case .instagram: has("^(edit profile|share profile)$")
                case .youtube: has("(^|[·•] )(view channel|your channel)$|^switch account$")
                case .x: has("^edit profile$") || labels(["profile", "premium", "bookmarks", "lists"]).count >= 2
                }
            }
        case .inlineTimer:
            return has(#"^[0-9]{1,2}:[0-9]{2}$"#) { $0.minY > 0.1 && topPost($0) }
        case .noResults:
            return has(#"^no results\b"#)
        case .launchScreen:
            let brands = networks.reduce(into: Set(["from", "meta", "from meta"])) { $0.insert($1.rawValue.lowercased()) }
            let body = lines.filter { $0.bounds.minY >= 0.045 }
            return body.count <= 2 && body.allSatisfy { brands.contains($0.label) } && !Self.tabBar.matches(regions, network: network)
        case .appStoreResult:
            let headers: Set = ["top hit", "siri suggestions", "suggestions", "app store", "get", "open", "apps"]
            let field = Self.searchFieldRows(regions)
            let results = lines.filter { line in !field.contains { abs($0 - line.bounds.midY) <= 0.02 } }
            guard let first = results.filter({ $0.bounds.minY >= 0.045 && !headers.contains($0.label) })
                .min(by: { $0.bounds.minY < $1.bounds.minY }) else { return false }
            return results.contains { line in
                (line.label == "get" && abs(line.bounds.midY - first.bounds.midY) <= 0.035)
                    || (line.label == "app store" && abs(line.bounds.minX - first.bounds.minX) < 0.05
                        && (first.bounds.maxY - 0.005...first.bounds.maxY + 0.03).contains(line.bounds.minY))
            }
        case .replyBar:
            return has(#"^(send message|post your reply|reply to .+)$"#) { $0.minY >= 0.75 }
        case .feedPost:
            return has(#"@[a-z0-9_]+ ?[·•] ?[0-9]"#) { (0.12..<0.6).contains($0.minY) }
                && !PhoneWatchChecks.postIdentity(in: .init(sourceID: "", capturedAt: .distantPast, platform: "", regions: regions)).isEmpty
        }
    }

    /// Whether the observer names the app, or an OCR row outside the search field is exactly its name.
    static func names(_ app: String, evidence: String, regions: [PhonePlaybackTracker.TextRegion]) -> Bool {
        let field = searchFieldRows(regions)
        return namesApp(app, in: evidence) || regions.contains { region in
            region.confidence >= 0.6 && label(region.text) == app.lowercased() && !field.contains { abs($0 - region.bounds.midY) <= 0.02 }
        }
    }

    /// Whether the observer names this app as the one on screen and no other supported network app (a TikTok watermark on a Reel).
    static func foregroundApp(_ app: String, evidence: String) -> Bool {
        namesApp(app, in: evidence) && !["TikTok", "Instagram", "YouTube"].contains { $0 != app && namesApp($0, in: evidence) }
    }

    /// Whether text names the app itself as a whole word, not a sibling app such as TikTok Studio or YouTube Music,
    /// outside a negated clause ("The TikTok icon is not visible").
    static func namesApp(_ app: String, in text: String) -> Bool {
        let pattern = #"(?i)(?<![\p{L}\p{N}])"# + NSRegularExpression.escapedPattern(for: app)
            + #"(?![\p{L}\p{N}])(?!\s+(studio|music|kids|lite|shop|business|creator|go)\b)"#
        return text.replacingOccurrences(of: "’", with: "'")
            .replacingOccurrences(of: #"(?i)\s+(but|while|whereas)\s+"#, with: ".", options: .regularExpression)
            .split(whereSeparator: { ".;!?\n".contains($0) }).contains { clause in
                clause.range(of: pattern, options: .regularExpression) != nil
                    && clause.range(of: #"(?i)\b(no|not|never|none|without|absent|missing|cannot)\b|n't\b"#, options: .regularExpression) == nil
            }
    }

    /// Row centers of a search field, read from its Cancel button, whose typed query is not a result.
    static func searchFieldRows(_ regions: [PhonePlaybackTracker.TextRegion]) -> [CGFloat] {
        regions.filter { $0.confidence >= 0.6 && label($0.text) == "cancel" }.map(\.bounds.midY)
    }

    static let tabs: [WarmUpScript.Network: Set<String>] = [
        .tikTok: ["home", "friends", "inbox", "profile"], .youtube: ["home", "shorts", "subscriptions", "you"]]
    static let placeholders: [WarmUpScript.Network: Set<String>] = [
        .tikTok: ["search"], .instagram: ["search", "ask meta ai or search"], .youtube: ["search youtube"], .x: ["search"]]
    static let results: [WarmUpScript.Network: (all: Set<String>, anchors: Set<String>)] = [
        .tikTok: (["top", "videos", "users", "sounds", "shop", "live", "photos", "hashtags", "places"], ["top", "videos", "users"]),
        .instagram: (["for you", "accounts", "reels", "audio", "tags", "places"], ["accounts", "audio", "tags"]),
        .youtube: (["all", "shorts", "videos", "unwatched", "watched", "recently uploaded", "live"], ["shorts", "videos", "unwatched"]),
        .x: (["top", "latest", "people", "media", "lists"], ["latest", "people"])]

    private static func label(_ text: String) -> String {
        text.lowercased().replacingOccurrences(of: "’", with: "'")
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
            .trimmingCharacters(in: CharacterSet(charactersIn: ">›〉").union(.whitespaces))
    }
}
