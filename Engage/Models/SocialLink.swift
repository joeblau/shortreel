import Foundation
import SwiftData
import SwiftUI

enum Platform: String, Codable, CaseIterable, Sendable {
    case instagram
    case tikTok
    case x
    case threads
    case youtube
    case facebook

    var displayName: String {
        switch self {
        case .instagram: "Instagram"
        case .tikTok: "TikTok"
        case .x: "X"
        case .threads: "Threads"
        case .youtube: "YouTube"
        case .facebook: "Facebook"
        }
    }

    var symbolName: String {
        switch self {
        case .instagram: "camera.fill"
        case .tikTok: "music.note"
        case .x: "xmark"
        case .threads: "at"
        case .youtube: "play.rectangle.fill"
        case .facebook: "person.2.fill"
        }
    }

    var color: Color {
        switch self {
        case .instagram: .pink
        case .tikTok: .cyan
        case .x: .primary
        case .threads: .indigo
        case .youtube: .red
        case .facebook: .blue
        }
    }
}

@Model
final class SocialLink {
    var platform: Platform
    var profileURL: URL
    var handle: String
    var account: Account?

    init(platform: Platform, profileURL: URL, handle: String, account: Account? = nil) {
        self.platform = platform
        self.profileURL = profileURL
        self.handle = handle
        self.account = account
    }
}
