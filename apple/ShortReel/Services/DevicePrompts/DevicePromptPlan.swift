import Foundation

enum PhoneSwipeDirection: String, Sendable, Equatable, CaseIterable {
    case up, down, left, right
}

enum PhoneKey: String, Sendable, Equatable, CaseIterable {
    case enter, escape, backspace, tab, search, selectAll, addressBar, appSwitcher, assistiveTouch
    case space, shiftTab, deleteForward, arrowUp, arrowDown, arrowLeft, arrowRight, copy, cut, paste, undo, redo
}

enum PhonePromptAction: Sendable, Equatable {
    case openApp(String)
    case home
    case search(String)
    case typeText(String)
    /// Coordinates are fractions of the screen, from zero to one.
    case tap(Double, Double)
    case doubleTap(Double, Double)
    case longPress(Double, Double, seconds: Double)
    case timedDrag(Double, Double, Double, Double, duration: Double, pressDuration: Double, holdDuration: Double)
    /// The direction the finger moves, which is opposite the scrolling direction.
    case swipe(PhoneSwipeDirection)
    case drag(Double, Double, Double, Double)
    case press(PhoneKey)
}

struct PhonePromptPlan: Sendable, Equatable {
    let actions: [PhonePromptAction]
}

/// The observable effect an action must produce before the run continues
/// (docs/execute-leg-design.md §command protocol). Every action carries one;
/// `none` is an explicit choice, not a forgotten check.
enum DeviceActionExpectation: Sendable, Equatable {
    /// The app is in the foreground. Plans carry display names until they can
    /// carry bundle IDs; the oracle matches either.
    case appForeground(bundleID: String)
    case textAppears(String)
    case textDisappears(String)
    /// The screen stops changing: the transition finished.
    case screenSettles
    case treeContains(String)
    case none
}

/// Verdict of one post-action verification check.
enum DevicePromptCheckOutcome: Sendable, Equatable {
    /// A rung positively confirmed the expectation; the string is the evidence.
    case satisfied(String)
    /// No verification rung was available. Treated as a pass so runs without
    /// an oracle or screen behave exactly as before.
    case unverified
    /// A rung positively refuted the expectation; the string is the evidence.
    case failed(String)

    var isResolved: Bool {
        switch self {
        case .satisfied, .unverified: true
        case .failed: false
        }
    }
}

/// Evaluates an expectation against the phone's current state.
typealias DevicePromptCheck = @MainActor () async -> DevicePromptCheckOutcome

/// Prepares the check for one action, capturing any pre-action baseline it
/// needs. Called immediately before the action executes.
typealias DevicePromptCheckFactory = @MainActor (DeviceActionExpectation) async -> DevicePromptCheck

extension PhonePromptAction {
    /// Explicit mechanics for model feedback/review; never a claim of success.
    var modelInputDescription: String {
        switch self {
        case .home: return "Home gesture: leave the foreground app; does not close it"
        case .press(.appSwitcher): return "App Switcher gesture: swipe from the bottom edge upward and hold before release"
        case .drag(let x, let y, let endX, let endY),
             .timedDrag(let x, let y, let endX, let endY, _, _, _):
            let direction = abs(endY - y) >= abs(endX - x)
                ? (endY < y ? "UP" : "DOWN") : (endX < x ? "LEFT" : "RIGHT")
            return "\(self): finger moves \(direction), from (x=\(x), y=\(y)) to (x=\(endX), y=\(endY)). Coordinates 0...1, y=0 at TOP and y=1 at BOTTOM."
        default: return String(describing: self)
        }
    }

    /// Default expectation when a planner does not declare one
    /// (docs/execute-leg-design.md §command protocol).
    var expectation: DeviceActionExpectation {
        switch self {
        case .openApp(let name): .appForeground(bundleID: name)
        case .home, .search, .typeText, .tap, .doubleTap, .longPress, .timedDrag, .swipe, .drag, .press: .screenSettles
        }
    }
}

enum PhonePromptPlanningError: LocalizedError, Equatable {
    case needsClarification(String)

    var errorDescription: String? {
        switch self {
        case .needsClarification(let explanation): explanation
        }
    }
}
