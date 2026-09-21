import Foundation
import SwiftData

enum InteractionKind: String, Codable, CaseIterable, Sendable {
    case scrollFeed
    case like
    case comment
    case follow
    case viewStory
    case savePost
    case search

    var symbolName: String {
        switch self {
        case .scrollFeed: "scroll"
        case .like: "heart.fill"
        case .comment: "bubble.right.fill"
        case .follow: "person.badge.plus"
        case .viewStory: "rectangle.stack"
        case .savePost: "bookmark.fill"
        case .search: "magnifyingglass"
        }
    }

    var label: String {
        switch self {
        case .scrollFeed: "Scroll feed"
        case .like: "Like"
        case .comment: "Comment"
        case .follow: "Follow"
        case .viewStory: "View story"
        case .savePost: "Save post"
        case .search: "Search"
        }
    }
}

enum EventStatus: String, Codable, Sendable {
    case scheduled
    case inProgress
    case completed
    case failed
}

@Model
final class TimelineEvent {
    var timestamp: Date
    var kind: InteractionKind
    var detail: String
    var status: EventStatus
    var platform: Platform
    var persona: Persona?

    init(
        timestamp: Date = .now,
        kind: InteractionKind,
        detail: String,
        status: EventStatus = .scheduled,
        platform: Platform,
        persona: Persona? = nil
    ) {
        self.timestamp = timestamp
        self.kind = kind
        self.detail = detail
        self.status = status
        self.platform = platform
        self.persona = persona
    }
}
