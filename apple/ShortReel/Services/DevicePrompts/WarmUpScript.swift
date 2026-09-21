import Foundation

enum WarmUpActivity: String, CaseIterable, Identifiable, Codable, Sendable {
    case watch, comment, post
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var symbol: String {
        switch self {
        case .watch: "play.rectangle"
        case .comment: "text.bubble"
        case .post: "square.and.arrow.up"
        }
    }
}

/// Built-in scripts describe milestones, never screen coordinates. The visual
/// runner verifies each milestone on a fresh image before advancing the cursor.
struct WarmUpScript: Codable, Equatable, Sendable {
    enum Network: String, CaseIterable, Codable, Sendable {
        case tikTok = "TikTok", instagram = "Instagram", youtube = "YouTube", x = "X"
    }
    enum StepID: String, Codable, Sendable {
        case account, search, suggestion, open, consume, advance
        case prepareSubmission, submit, verifySubmission
    }
    struct Step: Identifiable, Codable, Equatable, Sendable {
        let id: StepID
        let title: String
        let instruction: String
    }

    let version: Int
    let network: Network
    let activity: WarmUpActivity
    let itemLimit: Int
    let duration: TimeInterval

    init(network: Network, activity: WarmUpActivity, itemLimit: Int, duration: TimeInterval, version: Int = 1) {
        self.version = version
        self.network = network
        self.activity = activity
        self.itemLimit = itemLimit
        self.duration = duration
    }

    var identifier: String { "warmup.\(network.rawValue.lowercased()).\(activity.rawValue)" }
    var retryPolicy: RetryPolicy { .versionOne }

    /// Saved contracts fail before device input when their version or limits
    /// cannot be supported by this build.
    func validate() throws {
        guard version == 1 else { throw PhonePromptPlanningError.needsClarification("Unsupported warm-up script version: \(version).") }
        guard (1...50).contains(itemLimit), activity == .watch || itemLimit == 1 else {
            throw PhonePromptPlanningError.needsClarification("Watch supports 1–50 items; Comment and Post permit exactly one submission.")
        }
        guard duration.isFinite, duration > 0, duration <= 3_600 else {
            throw PhonePromptPlanningError.needsClarification("Warm-up duration must be positive and no longer than one hour.")
        }
    }

    enum CodingKeys: String, CodingKey { case version, network, activity, itemLimit, duration }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        version = try values.decode(Int.self, forKey: .version)
        network = try values.decode(Network.self, forKey: .network)
        activity = try values.decode(WarmUpActivity.self, forKey: .activity)
        itemLimit = try values.decode(Int.self, forKey: .itemLimit)
        duration = try values.decode(TimeInterval.self, forKey: .duration)
        try validate()
    }

    var title: String { "\(network.rawValue) · \(activity.title)" }
    var usesVideo: Bool { network != .x }
    var steps: [Step] {
        let account = Step(id: .account, title: "Verify account", instruction:
            "Perform the brief's account check. Finish only when the signed-in handle is visible and matches. A mismatch, sign-in screen, or unreadable handle requires input. Do not browse yet.")
        if activity == .post { return [account] + submissionSteps }
        let search: String
        let open: String
        let consume: String
        let advance: String
        switch network {
        case .tikTok:
            search = "Open TikTok search and type a simple 1–2 word niche query using typeText. Finish when the query and suggested searches are visible; do not submit yet."
            open = "Open a VIDEO FROM THE TOP ROW of the results grid, preferring top left. Use the Videos tab if needed. Do not scroll the grid or open an account/ad. Finish when the full-screen video is playing."
            consume = "Watch the current full-screen video TO COMPLETION. Compare timestamped frames and playback progress; an observed ending or verified replay counts once. Resume if paused. A delay or changing pixels alone is not completion. Do not swipe yet."
            advance = "Swipe UP EXACTLY ONCE within the full-screen player to the next video. Then wait and verify a different video is playing. Never scroll a results grid."
        case .instagram:
            search = "Search Instagram with a simple 1–2 word niche query using typeText, submit, and open the Reels results. Finish when Reel thumbnails are visible."
            open = "Open a relevant Reel from the top row. Finish when its full-screen player is playing, not a thumbnail preview or Story."
            consume = "Watch this Reel to completion. Use playback progress, its ending, or a verified replay as evidence. Resume if paused. Do not swipe yet."
            advance = "Swipe UP EXACTLY ONCE in the Reels player, then verify a different Reel starts playing."
        case .youtube:
            search = "Search YouTube with a simple 1–2 word niche query using typeText, submit, and open the Shorts results. Finish when Short thumbnails are visible."
            open = "Open a relevant Short from the top results. Finish only when the vertical Shorts player is playing. Avoid ads and long-form videos."
            consume = "Watch this Short to completion. Use playback progress, its ending, or a verified replay as evidence. Resume if paused. Do not swipe yet."
            advance = "Swipe UP EXACTLY ONCE in the Shorts player, then verify a different Short starts playing."
        case .x:
            search = "Search X with a simple 1–2 word niche query using typeText and submit. Finish when relevant post results are visible."
            open = "Locate the first relevant original post in the search feed. Keep the feed open. Avoid promoted posts, external links, and account-only results. Finish when the post text and author are readable."
            consume = "Read the current post and inspect its visible context. If it contains a video, watch it to completion. Finish with evidence of the specific post read. Do not scroll to another post yet."
            advance = "Scroll UP once through the results feed, then verify a different relevant post's text and author are visible. Do not open external links."
        }
        var result = [account, Step(id: .search, title: "Search niche", instruction: search)]
        if network == .tikTok {
            result.append(Step(id: .suggestion, title: "Choose search result", instruction:
                "Tap one of the TOP THREE relevant suggestions beneath the search field. Finish only when the video results grid is visible. A suggestion is not a video."))
        }
        result += [Step(id: .open, title: usesVideo ? "Open video" : "Find post", instruction: open),
                   Step(id: .consume, title: usesVideo ? "Watch to completion" : "Read post", instruction: consume)]
        if activity == .comment {
            result += submissionSteps
        } else {
            result.append(Step(id: .advance, title: usesVideo ? "Next video" : "Next post", instruction: advance))
        }
        return result
    }

    private var submissionSteps: [Step] {
        let preparation: String
        if activity == .comment {
            preparation = "Compose ONE short, relevant comment (reply on X) on the item just consumed, in the persona's voice and following the supplied instructions. Do not invent facts about unseen content."
        } else if network == .x {
            preparation = "Compose ONE original X post using the supplied post instructions."
        } else {
            preparation = "Prepare ONE native \(network.rawValue) post using the supplied instructions and existing media explicitly identified there. Never invent or substitute assets; request input if they cannot be found."
        }
        return [
            Step(id: .prepareSubmission, title: "Prepare \(activity.title.lowercased())", instruction:
                preparation + " Finish only when the exact composed text and selected media are ready, the correct account and target are verified, and the send/publish control is visible. Do not tap send/publish in this step."),
            Step(id: .submit, title: "Submit once", instruction:
                "Tap the visible send/publish control EXACTLY ONCE for the prepared \(activity.title.lowercased()). No typing, navigation, or repeated taps. If the target or content changed, request input. The runner immediately switches to verification after this tap."),
            Step(id: .verifySubmission, title: "Verify publication", instruction:
                "The submission was already sent. Observe the result and verify that this exact \(activity.title.lowercased()) appears under the correct account and target. Do not send any input or publish again. Wait only for loading; return finished with visible evidence when published. On error, uncertainty, or missing confirmation, request input. Never retry submission.")
        ]
    }
}


struct WarmUpScriptCursor: Sendable {
    let script: WarmUpScript
    private(set) var index = 0
    private(set) var itemsCompleted = 0
    private(set) var advanceSent = false
    private(set) var submissionSent = false
    private(set) var isComplete = false
    var step: WarmUpScript.Step { script.steps[index] }
    var progress: String {
        "\(script.title) · \(isComplete ? "Complete" : step.title)"
            + (script.activity == .post ? "" : " · \(itemsCompleted)/\(script.itemLimit) viewed")
    }

    func goal(_ brief: String) -> String {
        """
        \(brief)

        ACTIVE SCRIPT: \(script.title) (\(script.identifier) v\(script.version)). Step \(index + 1)/\(script.steps.count): \(step.title). \(itemsCompleted)/\(script.itemLimit) items completed.
        Execute ONLY this step: \(step.instruction)
        Return finished with visible evidence when THIS STEP is verified, not when the entire session finishes. The runner owns step transitions and item counts. Do not execute future steps. Account verification remains valid after its step; stop if the app changes account or requests sign-in.
        \(script.activity == .watch ? "Watch only: no likes, follows, comments, messages, or publishing." : "Only the selected activity is authorized: no unrelated engagement, messages, likes, or follows. Publish at most one \(script.activity == .post ? "post" : "comment") in this run.")
        \(advanceSent ? "The advance gesture was already sent. Verify the new item now; do not send another gesture. If the transition failed, request input." : "")
        """
    }

    func validate(_ action: PhonePromptAction) throws {
        try script.validate()
        guard !isComplete else {
            throw PhonePromptPlanningError.needsClarification("This script is already complete.")
        }
        if step.id == .submit {
            guard !submissionSent, case .tap = action else {
                throw PhonePromptPlanningError.needsClarification("Submit the prepared content with exactly one tap.")
            }
        }
        if step.id == .verifySubmission {
            throw PhonePromptPlanningError.needsClarification("Submission was sent. Verify the result without further input; never resubmit an uncertain publication.")
        }
        if step.id == .advance {
            guard !advanceSent, action == .swipe(.up) else {
                throw PhonePromptPlanningError.needsClarification("The script needs one upward swipe followed by verification of the next item.")
            }
        }
        if step.id == .consume {
            switch action {
            case .swipe, .drag, .timedDrag:
                throw PhonePromptPlanningError.needsClarification("Verify the current item is complete before advancing to the next one.")
            default: break
            }
        }
    }

    mutating func didPerform(_ action: PhonePromptAction) {
        if step.id == .advance, action == .swipe(.up) { advanceSent = true }
        if step.id == .submit, !submissionSent, case .tap = action {
            submissionSent = true
            index += 1
        }
    }

    mutating func finishStep() throws {
        try script.validate()
        guard !isComplete else { return }
        if step.id == .submit {
            throw PhonePromptPlanningError.needsClarification("Submission requires one send/publish tap before verification.")
        }
        if step.id == .verifySubmission, !submissionSent {
            throw PhonePromptPlanningError.needsClarification("Cannot confirm a publication that was never submitted.")
        }
        if step.id == .advance {
            guard advanceSent else {
                throw PhonePromptPlanningError.needsClarification("The next item cannot be verified before the upward swipe is sent.")
            }
            index = script.steps.firstIndex { $0.id == .consume }!
            advanceSent = false
            return
        }
        if step.id == .consume {
            itemsCompleted += 1
            if script.activity == .watch, itemsCompleted >= script.itemLimit {
                isComplete = true
                return
            }
        }
        if index == script.steps.count - 1 { isComplete = true }
        else { index += 1 }
    }
}

extension WarmUpScript {
    struct RetryPolicy: Codable, Equatable, Sendable {
        let maximumPreparationAttempts: Int
        let maximumSubmissionAttempts: Int
        let retriesUncertainSubmission: Bool
        let resumesInterruptedRun: Bool

        /// A fresh run requires explicit user action. In-step observation and
        /// loading waits are not retries of preparation or publication.
        static let versionOne = RetryPolicy(maximumPreparationAttempts: 1,
            maximumSubmissionAttempts: 1, retriesUncertainSubmission: false, resumesInterruptedRun: false)
    }
}

/// Registry keys remain stable across display-name changes; a version changes
/// whenever the steps or retry contract change. Older versions must either keep
/// their own definition or be rejected explicitly, never silently upgraded.
enum WarmUpScriptRegistry {
    struct Definition: Equatable, Sendable {
        let identifier: String
        let version: Int
        let network: WarmUpScript.Network
        let activity: WarmUpActivity
    }

    static var definitions: [Definition] {
        WarmUpScript.Network.allCases.flatMap { network in
            WarmUpActivity.allCases.map { activity in
                let script = WarmUpScript(network: network, activity: activity, itemLimit: 1, duration: 300)
                return Definition(identifier: script.identifier, version: script.version, network: network, activity: activity)
            }
        }
    }

    static func script(network: WarmUpScript.Network, activity: WarmUpActivity,
                       itemLimit: Int, duration: TimeInterval, version: Int = 1) throws -> WarmUpScript {
        let script = WarmUpScript(network: network, activity: activity, itemLimit: itemLimit, duration: duration, version: version)
        try script.validate()
        return script
    }
}

/// A durable run records the executable definition alongside its settings, so
/// inspecting history does not reinterpret old runs using a newer playbook.
struct WarmUpScriptEnvelope: Codable, Equatable, Sendable {
    let schemaVersion: Int
    let script: WarmUpScript
    let steps: [WarmUpScript.Step]
    let retryPolicy: WarmUpScript.RetryPolicy

    init(script: WarmUpScript) throws {
        try script.validate()
        schemaVersion = 1
        self.script = script
        steps = script.steps
        retryPolicy = script.retryPolicy
    }

    func validate() throws {
        try script.validate()
        guard schemaVersion == 1, steps == script.steps, retryPolicy == script.retryPolicy else {
            throw PhonePromptPlanningError.needsClarification("This saved warm-up definition does not match a supported script contract.")
        }
    }

    enum CodingKeys: String, CodingKey { case schemaVersion, script, steps, retryPolicy }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try values.decode(Int.self, forKey: .schemaVersion)
        script = try values.decode(WarmUpScript.self, forKey: .script)
        steps = try values.decode([WarmUpScript.Step].self, forKey: .steps)
        retryPolicy = try values.decode(WarmUpScript.RetryPolicy.self, forKey: .retryPolicy)
        try validate()
    }
}

/// Diagnostic progress only. Interrupted runs are never automatically resumed:
/// the screen/account can change, and a submitted action may be unconfirmed.
struct WarmUpScriptCheckpoint: Codable, Equatable, Sendable {
    let scriptIdentifier: String
    let scriptVersion: Int
    let index: Int
    let itemsCompleted: Int
    let advanceSent: Bool
    let submissionSent: Bool
    let isComplete: Bool
}

extension WarmUpScriptCursor {
    var checkpoint: WarmUpScriptCheckpoint {
        WarmUpScriptCheckpoint(scriptIdentifier: script.identifier, scriptVersion: script.version,
            index: index, itemsCompleted: itemsCompleted, advanceSent: advanceSent,
            submissionSent: submissionSent, isComplete: isComplete)
    }
}
