import Foundation

enum PhoneSwipeDirection: String, Sendable, Equatable, CaseIterable {
    case up, down, left, right
}

enum PhoneKey: String, Sendable, Equatable, CaseIterable {
    case enter, escape, backspace, tab, search, selectAll, addressBar
}

enum PhonePromptAction: Sendable, Equatable {
    case openApp(String)
    case home
    case search(String)
    case typeText(String)
    /// Coordinates are fractions of the screen, from zero to one.
    case tap(Double, Double)
    /// The direction the finger moves, which is opposite the scrolling direction.
    case swipe(PhoneSwipeDirection)
    case drag(Double, Double, Double, Double)
    case press(PhoneKey)
}

struct PhonePromptPlan: Sendable, Equatable {
    let actions: [PhonePromptAction]
}

enum PhonePromptPlanningError: LocalizedError, Equatable {
    case needsClarification(String)

    var errorDescription: String? {
        switch self {
        case .needsClarification(let explanation): explanation
        }
    }
}
