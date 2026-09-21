import Foundation

/// Stand-in for a real device driver: waits a randomized 1–3s like a real UI
/// automation pass would, then returns a plausible result string.
@MainActor
struct SimulatedDeviceController: DeviceControlling {
    enum SimulatedFailure: Error {
        case deviceHiccup
    }

    func perform(_ action: DeviceAction, on persona: Persona) async throws -> String {
        try await Task.sleep(for: .seconds(Double.random(in: 1...3)))
        if Double.random(in: 0...1) < 0.04 {
            throw SimulatedFailure.deviceHiccup
        }
        return Self.resultString(for: action)
    }

    private static func resultString(for action: DeviceAction) -> String {
        let tag = "#\(action.keyword.replacingOccurrences(of: " ", with: ""))"
        switch action.kind {
        case .scrollFeed:
            return "Scrolled the \(action.platform.displayName) home feed for a few minutes"
        case .like:
            return "Liked a post tagged \(tag)"
        case .comment:
            let comments = ["Love this!", "So good.", "Great work, keep it up.", "This is exactly what I needed to see."]
            return "Commented \"\(comments.randomElement()!)\" on a \(tag) post"
        case .follow:
            return "Followed a creator posting about \(tag)"
        case .viewStory:
            return "Watched stories from the \(tag) topic page"
        case .savePost:
            return "Saved a \(tag) post to a collection"
        case .search:
            return "Searched for \"\(action.keyword)\" and browsed results"
        }
    }
}
