import Foundation

struct PhoneSubmissionCheckpoint: Codable, Sendable, Equatable {
    enum State: String, Codable, Sendable {
        case preparing, submitting, confirmed, uncertain
    }

    let state: State
    let activity: String
    let updatedAt: Date
    let detail: String

    var requiresReview: Bool { state == .submitting || state == .uncertain }
}
