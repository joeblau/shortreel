import Foundation

enum PhoneWatchChecks {
    static func question(id: String, check: PhoneTransactionPlan.State.Check, evidence: String) -> PhoneTransactionQuestion? {
        let options: [(String, String)]
        switch check {
        case .query: return nil
        case .popularVideo:
            options = [("player", "A full-screen video player."), ("ad", "An advertisement."),
                       ("profile", "A social media profile page."), ("unknown", "A different or unreadable screen.")]
        case .playback:
            options = [("playing", "A playing video."), ("paused", "A paused video with a play button."),
                       ("unknown", "A screen without a readable video player.")]
        case .advance:
            options = [("player", "A full-screen video player."), ("results", "A grid of video search results."),
                       ("unknown", "A different or unreadable screen.")]
        }
        return .init(id: id, evidence: evidence,
            options: options.map { .init(id: $0.0, description: $0.1) }, question: "What is visible on the screen?")
    }

    static func branch(for selected: String?, check: PhoneTransactionPlan.State.Check,
                       evidence: String, duration: Int?, replay: Bool, advanceSent: Bool) -> String? {
        switch check {
        case .query: return selected
        case .popularVideo:
            if selected == "ad" || selected == "profile" { return "opened-account-or-ad" }
            guard selected == "player" else { return nil }
            guard let count = heartCount(in: evidence) else { return "threshold-unreadable" }
            return count > 10_000 ? "qualified" : "below"
        case .playback:
            guard selected == "playing" || selected == "paused" else { return nil }
            if let duration, duration > 60 { return "too-long" }
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

    static func queryVisible(_ query: String, in text: PhonePlaybackTracker.Observation) -> Bool {
        text.regions.contains {
            $0.confidence >= 0.6 && $0.bounds.minY < 0.25 &&
            $0.text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == query.lowercased()
        }
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

struct PhoneVideoProgressTracker {
    private var previous: (video: PhoneScreenObservation.Video, date: Date)?
    private var advanced = false
    private var estimates: [Double] = []

    mutating func reset() { previous = nil; advanced = false; estimates = [] }

    mutating func observe(_ video: PhoneScreenObservation.Video?, at date: Date) -> PhonePlaybackEvidence {
        guard let video, video.isValid, video.identity.count == 2, let progress = video.progress else {
            reset()
            return .init(summary: "No readable video identity and playhead position.", replayCandidate: false)
        }
        let readableDuration = video.durationSeconds.map { Int($0.rounded()) }
        defer { previous = (video, date) }
        guard let previous, previous.video.identity == video.identity,
              let before = previous.video.progress, date > previous.date,
              date.timeIntervalSince(previous.date) <= 30 else {
            advanced = false; estimates = []
            return .init(summary: "Visible playhead at \(Int(progress * 100))%; observing continuity.",
                replayCandidate: false, durationSeconds: readableDuration)
        }
        if video.playing == false || previous.video.playing == false {
            advanced = false; estimates = []
            return .init(summary: "Playback is paused; no completion established.", replayCandidate: false, durationSeconds: readableDuration)
        }
        if advanced, before >= 0.9, progress <= 0.1 {
            advanced = false
            return .init(summary: "The same creator and caption advanced to the end, then the playhead reset near the beginning.",
                replayCandidate: true, durationSeconds: readableDuration)
        }
        let seconds = date.timeIntervalSince(previous.date)
        let delta = progress - before
        if delta > 0.01 {
            let plausible = video.durationSeconds.map { delta * $0 <= seconds * 2 + 2 } ?? (delta <= 0.5)
            advanced = plausible
            if plausible, seconds >= 3 {
                estimates.append(seconds / delta)
                estimates = Array(estimates.suffix(2))
            } else { estimates = [] }
        } else if delta < 0 { advanced = false; estimates = [] }
        var duration = readableDuration
        if duration == nil, estimates.count == 2, let low = estimates.min(), let high = estimates.max(),
           low > 60, high / low <= 1.25 {
            duration = Int(low.rounded(.down))
        }
        return .init(summary: "Visible playhead at \(Int(progress * 100))%; completion not established.",
            replayCandidate: false, durationSeconds: duration, isAdvancing: delta > 0.01 && advanced)
    }
}
