import Foundation

/// Written before the irreversible input. A crash while `submitting` is an
/// uncertain result, never permission to send the same comment/post again.
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
