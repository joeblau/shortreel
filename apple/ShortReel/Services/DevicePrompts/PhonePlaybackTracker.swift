import CoreGraphics
import Foundation
import Vision

struct PhonePlaybackEvidence: Sendable, Equatable {
    let summary: String
    let replayCandidate: Bool
    var durationSeconds: Int? = nil
    var isAdvancing = false
}

struct PhonePlaybackTracker: Sendable {
    struct TextRegion: Sendable {
        let text: String
        let confidence: Float
        let bounds: CGRect
    }

    struct Observation: Sendable {
        let sourceID: String
        let capturedAt: Date
        let platform: String
        let regions: [TextRegion]
    }

    private struct Sample: Sendable {
        let sourceID: String
        let capturedAt: Date
        let platform: String
        let elapsed: Int
        let total: Int
        let timerBounds: CGRect
        let identity: Set<String>
    }

    private var previous: Sample?
    private var observedForwardProgress = false

    mutating func reset() {
        previous = nil
        observedForwardProgress = false
    }

    mutating func observe(frame: PhoneScreenFrame, platform: String) async -> PhonePlaybackEvidence {
        observe(await Self.read(frame: frame, platform: platform))
    }

    static func read(frame: PhoneScreenFrame, platform: String) async -> Observation {
        await Task.detached(priority: .utility) {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.recognitionLanguages = ["en-US"]
            request.usesLanguageCorrection = false
            do {
                try VNImageRequestHandler(cgImage: frame.cgImage).perform([request])
                let regions = (request.results ?? []).compactMap { result -> TextRegion? in
                    guard let candidate = result.topCandidates(1).first else { return nil }
                    let box = result.boundingBox
                    return TextRegion(text: candidate.string, confidence: candidate.confidence,
                        bounds: CGRect(x: box.minX, y: 1 - box.maxY, width: box.width, height: box.height))
                }
                return Observation(sourceID: frame.sourceID, capturedAt: frame.capturedAt,
                    platform: platform, regions: regions)
            } catch {
                return Observation(sourceID: frame.sourceID, capturedAt: frame.capturedAt,
                    platform: platform, regions: [])
            }
        }.value
    }

    mutating func observe(_ observation: Observation) -> PhonePlaybackEvidence {
        let timers = observation.regions.compactMap { region -> (TextRegion, Int, Int)? in
            guard region.confidence >= 0.85, region.bounds.minY >= 0.50,
                  region.bounds.maxY <= 0.98, region.bounds.height <= 0.065,
                  let pair = Self.timerPair(region.text) else { return nil }
            return (region, pair.0, pair.1)
        }
        guard timers.count == 1, let timer = timers.first else {
            reset()
            return .init(summary: "Local playback detector: no unique readable elapsed/total timer. Completion is unconfirmed; inspect the actual player and progress/replay visually. Do not infer completion from elapsed wall time or changing pixels.", replayCandidate: false)
        }

        let identity = Set(observation.regions.compactMap { region -> String? in
            guard region.confidence >= 0.85, region.bounds.minY >= 0.50,
                  region.bounds.minY < 0.90, region.bounds.minX < 0.55,
                  Self.timerPair(region.text) == nil else { return nil }
            let normalized = region.text.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
            guard normalized.count >= 8, normalized.count <= 200,
                  !Self.controlLabels.contains(where: normalized.contains) else { return nil }
            if normalized.first == "@", normalized.range(of: #"^@[a-z0-9_.]{3,40}$"#, options: .regularExpression) != nil {
                return normalized
            }
            guard normalized.split(separator: " ").count >= 4 else { return nil }
            return normalized
        })
        let current = Sample(sourceID: observation.sourceID, capturedAt: observation.capturedAt,
            platform: observation.platform, elapsed: timer.1, total: timer.2,
            timerBounds: timer.0.bounds, identity: identity)
        defer { previous = current }

        let measured = "Local playback detector: visible timer \(Self.clock(current.elapsed))/\(Self.clock(current.total)) (\(Int(Double(current.elapsed) / Double(current.total) * 100))%)."
        guard let previous,
              previous.sourceID == current.sourceID, previous.platform == current.platform,
              current.capturedAt > previous.capturedAt,
              current.capturedAt.timeIntervalSince(previous.capturedAt) <= 30,
              previous.total == current.total,
              abs(previous.timerBounds.midY - current.timerBounds.midY) <= 0.025,
              abs(previous.timerBounds.midX - current.timerBounds.midX) <= 0.05,
              identity.count >= 2, identity.contains(where: { $0.first == "@" }),
              previous.identity == identity else {
            observedForwardProgress = false
            return .init(summary: measured + " Same-video continuity is unconfirmed. A timer alone does not prove this is the active player or that playback completed.", replayCandidate: false, durationSeconds: current.total)
        }

        let resetFromEnd = observedForwardProgress
            && Double(previous.elapsed) / Double(previous.total) >= 0.90
            && current.elapsed <= max(1, Int(Double(current.total) * 0.10))
        if resetFromEnd {
            observedForwardProgress = false
            return .init(summary: measured + " Previously advanced to \(Self.clock(previous.elapsed))/\(Self.clock(previous.total)), then reset near zero while creator/caption anchors and timer position stayed the same. This is a replay candidate: visually confirm the same full-screen video completed before marking it watched and swiping up once. Seeking, overlays, or a different video can also reset a timer.", replayCandidate: true, durationSeconds: current.total)
        }
        if current.elapsed > previous.elapsed {
            let maximumAdvance = current.capturedAt.timeIntervalSince(previous.capturedAt) * 2 + 2
            observedForwardProgress = Double(current.elapsed - previous.elapsed) <= maximumAdvance
        } else if current.elapsed < previous.elapsed {
            observedForwardProgress = false
        }
        return .init(summary: measured + " No completion established. A static, paused, or near-end timer is not a completed viewing.", replayCandidate: false, durationSeconds: current.total, isAdvancing: current.elapsed > previous.elapsed && observedForwardProgress)
    }

    private static let controlLabels = ["add comment", "add a comment", "write a comment", "search", "suggested", "for you", "following", "subscribe", "share", "log in", "sign in", "people also"]

    private static func timerPair(_ text: String) -> (Int, Int)? {
        let compact = text.filter { !$0.isWhitespace }
        let pieces = compact.split(separator: "/", omittingEmptySubsequences: false)
        guard pieces.count == 2, let elapsed = seconds(String(pieces[0])),
              let total = seconds(String(pieces[1])), (3...21_600).contains(total),
              elapsed >= 0, elapsed <= total else { return nil }
        return (elapsed, total)
    }

    private static func seconds(_ text: String) -> Int? {
        let parts = text.split(separator: ":", omittingEmptySubsequences: false)
        guard (2...3).contains(parts.count), parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isASCII) && $0.allSatisfy(\.isNumber) }),
              parts.dropFirst().allSatisfy({ $0.count == 2 }),
              let last = Int(parts.last!), last < 60 else { return nil }
        var value = 0
        for (index, part) in parts.enumerated() {
            guard let number = Int(part), number <= 360,
                  index == 0 || number < 60 else { return nil }
            value = value * 60 + number
        }
        return value
    }

    private static func clock(_ seconds: Int) -> String {
        String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}
