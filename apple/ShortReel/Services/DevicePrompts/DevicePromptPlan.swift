import Foundation

enum PhoneSearchGuidance {
    static let playbackCompletionReview = """
        PLAYBACK COMPLETION REVIEW: Repeated waits have not advanced to another video. Compare the timestamped watching-start image, recent frames, and CURRENT frame. Check actual playback progress, the same video's ending, or its progress resetting into a replay. A verified replay means it already completed once; do not wait for the replay to finish. If the video completed during an ACTIVE SCRIPT watch step, return finished with completion evidence so the runner advances the script. Without a script, if session limits allow another, return swipe UP now and verify the next video on the following screenshot. Return wait only when current evidence shows the first viewing is still playing or a transition is loading. Do not reuse an earlier estimated percentage or treat changing video pixels as proof it has not completed. If paused, resume it. If completion cannot be determined, inspect a visible playback/progress control rather than repeating an unsupported wait. Never advance from a results grid or change the brief's account check or session limits.
        """
    static let tikTokViewing = """
        TikTok search sequence: after typing the short query, inspect the suggested-search list under the search field. Tap one of its TOP THREE relevant suggestions, using its displayed wording. These are search suggestions, not videos; prefer a suggestion over pressing Enter or Search when one is available. Wait for the video results grid, then select a VIDEO FROM THE TOP ROW of results using its visible thumbnail in the current screenshot; use the Videos tab if needed. Open a top-row video before scrolling anywhere. Do not mistake a search suggestion, account, or advertisement for that video. Verify the full-screen player and let playback start; use its observed play control if paused. Watch the current video TO COMPLETION before advancing. Wait and inspect fresh screenshots for playback progress, a visible end state, or a verified loop restart; an arbitrary short delay is not proof that it finished. Do not skip ahead while it is still playing. Once completion is observed, count that video once and, if the session limits allow another, swipe UP EXACTLY ONCE within the player. Verify that a different video has started, watch it to completion, and repeat. Do not repeatedly swipe while a transition is still loading. Search-result grids and thumbnail previews do not count as watched videos. If you return to the grid, select a video from its top row before resuming. Never keep scrolling search results as though they were the video feed.
        """

    static let instructions = """
        When an ACTIVE SCRIPT is present, execute only its current step. The sequences below provide navigation context, not permission to skip ahead. Return finished when that step is verified; the runner advances the script. Never swipe during its watch step or repeat a gesture already sent in its advance step.
        Keep the search text YOU TYPE very simple: only 1–2 words, such as "stocks", "trading", "swing trading", or "street photography". Never type sentences, persona descriptions, stacked keywords, or advanced operators into search. If results are poor, try a different simple term instead of making the typed query longer. TikTok's native suggestions may be longer; choose them as displayed following the sequence below.
        To enter text, first focus the visible text field, then use the typeText action (type(content=...) for UI-TARS). ShortReel sends actual keyboard keystrokes character by character with varied pauses. Supply the complete intended text in one action; do not paste from the clipboard, tap individual on-screen letter keys, or split each letter into a separate planner decision. Inspect the typed result before the next action. On TikTok, next choose a search suggestion as described below.
        \(tikTokViewing)
        """
}

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
