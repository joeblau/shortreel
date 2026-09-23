import Foundation

enum PhoneSearchGuidance {
    static let playbackCompletionReview = """
        PLAYBACK COMPLETION REVIEW: Repeated waits have not advanced to another video. Compare the timestamped watching-start image, recent frames, and CURRENT frame. Check actual playback progress, the same video's ending, or its progress resetting into a replay. A verified replay means it already completed once; do not wait for the replay to finish. If the video completed during an ACTIVE SCRIPT watch step, return finished with completion evidence so the runner advances the script. Without a script, if session limits allow another, return swipe UP now and verify the next video on the following screenshot. If the active script allows a duration skip and its evidence rule is met, return one upward swipe immediately without counting that video. When the script allows estimated length, use visible playback progress across timestamped frames to judge whether it looks longer than the active script’s duration limit; do not insist on an exact timer. Otherwise return wait only when current evidence shows the first viewing is still playing or a transition is loading. Do not reuse an earlier estimated percentage or treat changing video pixels as proof it has not completed. If paused, resume it. If completion cannot be determined, inspect a visible playback/progress control rather than repeating an unsupported wait. Never advance from a results grid or change the brief's account check or session limits.
        """
    static let tikTokViewing = """
        TikTok search sequence: after typing the short query, inspect the suggested-search list under the search field. Tap one of its TOP THREE relevant suggestions, using its displayed wording. These are search suggestions, not videos; prefer a suggestion over pressing Enter or Search when one is available. Wait for the video results grid, then follow the ACTIVE SCRIPT’s starting-video selection rule. Without an active script, start at the top of results and choose a relevant video with more than 10,000 hearts, verified next to the heart in its full-screen player; views do not qualify. If a candidate has too few or unreadable hearts, go back and inspect the next result; scroll results if needed. Do not count rejected candidates as watched or lower the threshold. Do not mistake a search suggestion, account, or advertisement for that video. Verify the full-screen player and let playback start; use its observed play control if paused. Follow any ACTIVE SCRIPT duration limit first: skip a visibly overlong video without counting it. Otherwise watch the current video TO COMPLETION before advancing. Wait and inspect fresh screenshots for playback progress, a visible end state, or a verified loop restart; an arbitrary short delay is not proof that it finished. Do not skip ahead while it is still playing unless the active script explicitly allows a duration-based skip. Once completion is observed, count that video once and, if the session limits allow another, swipe UP EXACTLY ONCE within the player. Verify that a different video has started, watch it to completion, and repeat. Do not repeatedly swipe while a transition is still loading. Search-result grids and thumbnail previews do not count as watched videos. If you return to the grid, follow the starting-video selection rule before resuming playback. Never keep scrolling search results as though they were the video feed.
        """

    static let instructions = """
        When an ACTIVE SCRIPT is present, execute only its current step. The sequences below provide navigation context, not permission to skip ahead. Return finished when that step is verified; the runner advances the script. During a watch step, swipe only for an explicit script exception such as a visibly overlong video; never repeat a gesture already sent in its advance step.
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
    case tap(Double, Double)
    case doubleTap(Double, Double)
    case longPress(Double, Double, seconds: Double)
    case timedDrag(Double, Double, Double, Double, duration: Double, pressDuration: Double, holdDuration: Double)
    case swipe(PhoneSwipeDirection)
    case drag(Double, Double, Double, Double)
    case press(PhoneKey)
}

struct PhonePromptPlan: Sendable, Equatable {
    let actions: [PhonePromptAction]
}

enum DeviceActionExpectation: Sendable, Equatable {
    case appForeground(bundleID: String)
    case textAppears(String)
    case textDisappears(String)
    case screenSettles
    case treeContains(String)
    case none
}

enum DevicePromptCheckOutcome: Sendable, Equatable {
    case satisfied(String)
    case unverified
    case failed(String)

    var isResolved: Bool {
        switch self {
        case .satisfied, .unverified: true
        case .failed: false
        }
    }
}

typealias DevicePromptCheck = @MainActor () async -> DevicePromptCheckOutcome

typealias DevicePromptCheckFactory = @MainActor (DeviceActionExpectation) async -> DevicePromptCheck

extension PhonePromptAction {
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
