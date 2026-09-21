import Foundation

/// One phase of a platform's warm-up schedule: what the agent may do,
/// how much of it, and what is still off-limits that day.
struct WarmUpPhasePlan: Sendable {
    var title: String
    var firstDay: Int
    /// nil means the phase continues indefinitely.
    var lastDay: Int?
    var activities: [InteractionKind]
    var maxLikes: Int
    var maxFollows: Int
    var maxComments: Int
    var maxPosts: Int
    var allowsDirectMessages: Bool
    var allowsPosting: Bool { maxPosts > 0 }
    /// Platform- and phase-specific behavior injected into the prompt.
    var guidance: String

    func contains(day: Int) -> Bool {
        day >= firstDay && day <= (lastDay ?? .max)
    }
}

/// Gradual, human-looking activity ramps for new accounts. Consume more
/// than you post early; raise volume slowly; keep early content casual.
enum WarmUpPlaybook {
    static let platforms: [Platform] = [.tikTok, .instagram, .x, .youtube]

    static func phases(for platform: Platform) -> [WarmUpPhasePlan] {
        switch platform {
        case .x:
            [
                WarmUpPhasePlan(
                    title: "Days 1–3", firstDay: 1, lastDay: 3,
                    activities: [.scrollFeed, .like, .follow],
                    maxLikes: 5, maxFollows: 5, maxComments: 0, maxPosts: 0,
                    allowsDirectMessages: false,
                    guidance: "Scroll the feed and read. Like only a few posts and follow a handful of relevant accounts. Do not post, reply, send messages, or open links."
                ),
                WarmUpPhasePlan(
                    title: "Days 4–7", firstDay: 4, lastDay: 7,
                    activities: [.scrollFeed, .like, .comment, .follow],
                    maxLikes: 15, maxFollows: 8, maxComments: 3, maxPosts: 2,
                    allowsDirectMessages: false,
                    guidance: "Mix scrolling with light engagement. Plain-thought posts or real replies only — nothing promotional, no links. Spread actions across the session."
                ),
                WarmUpPhasePlan(
                    title: "Days 8–14+", firstDay: 8, lastDay: nil,
                    activities: [.scrollFeed, .like, .comment, .follow],
                    maxLikes: 25, maxFollows: 12, maxComments: 6, maxPosts: 3,
                    allowsDirectMessages: true,
                    guidance: "Raise posting slightly, still mixed with replies and likes. Direct messages only if genuinely conversational: unique text, no links, at most one or two."
                ),
            ]
        case .tikTok:
            [
                WarmUpPhasePlan(
                    title: "Days 1–3", firstDay: 1, lastDay: 3,
                    activities: [.scrollFeed, .search, .like, .follow],
                    maxLikes: 8, maxFollows: 5, maxComments: 0, maxPosts: 0,
                    allowsDirectMessages: false,
                    guidance: "Watch each video to completion, then swipe up once to the next video. Search the niche a few times so the feed starts matching it. Like sparingly and follow only a few real accounts. Do not post."
                ),
                WarmUpPhasePlan(
                    title: "Days 4–7", firstDay: 4, lastDay: 7,
                    activities: [.scrollFeed, .search, .like, .comment, .follow],
                    maxLikes: 15, maxFollows: 8, maxComments: 3, maxPosts: 1,
                    allowsDirectMessages: false,
                    guidance: "Keep watching most of the session. Add a few genuine comments and more niche follows. If posting, the first video must feel native: vertical, relevant sound, not a hard sell."
                ),
                WarmUpPhasePlan(
                    title: "Week 2+", firstDay: 8, lastDay: nil,
                    activities: [.scrollFeed, .search, .like, .comment, .follow],
                    maxLikes: 25, maxFollows: 12, maxComments: 6, maxPosts: 2,
                    allowsDirectMessages: false,
                    guidance: "Look like someone who both watches and creates: keep watching and engaging daily around any posting."
                ),
            ]
        case .instagram:
            [
                WarmUpPhasePlan(
                    title: "Days 1–3", firstDay: 1, lastDay: 3,
                    activities: [.scrollFeed, .viewStory, .like, .follow],
                    maxLikes: 8, maxFollows: 5, maxComments: 0, maxPosts: 0,
                    allowsDirectMessages: false,
                    guidance: "Scroll the feed, Reels, and Stories. Like a small number of posts and follow a few relevant accounts. No posts, no messages, no bio link."
                ),
                WarmUpPhasePlan(
                    title: "Days 4–7", firstDay: 4, lastDay: 7,
                    activities: [.scrollFeed, .viewStory, .like, .comment, .follow],
                    maxLikes: 15, maxFollows: 8, maxComments: 3, maxPosts: 1,
                    allowsDirectMessages: false,
                    guidance: "Stay mostly a consumer: light likes and a few real comments. At most one casual post or Story — nothing promotional."
                ),
                WarmUpPhasePlan(
                    title: "Days 8–14+", firstDay: 8, lastDay: nil,
                    activities: [.scrollFeed, .viewStory, .like, .comment, .follow, .savePost],
                    maxLikes: 25, maxFollows: 12, maxComments: 6, maxPosts: 1,
                    allowsDirectMessages: true,
                    guidance: "Introduce Reels or feed posts slowly (at most one per session). View Stories and reply occasionally. Keep follows modest. Messages only as real conversations."
                ),
            ]
        case .youtube:
            [
                WarmUpPhasePlan(
                    title: "Days 1–4", firstDay: 1, lastDay: 4,
                    activities: [.scrollFeed, .search, .like, .follow, .comment],
                    maxLikes: 8, maxFollows: 5, maxComments: 3, maxPosts: 0,
                    allowsDirectMessages: false,
                    guidance: "Be a viewer in the niche: watch videos to the end, like a few you genuinely like, subscribe to a small number of related channels, and leave only real comments — never generic praise. Do not upload."
                ),
                WarmUpPhasePlan(
                    title: "Day 5+", firstDay: 5, lastDay: nil,
                    activities: [.scrollFeed, .search, .like, .follow, .comment],
                    maxLikes: 15, maxFollows: 8, maxComments: 5, maxPosts: 1,
                    allowsDirectMessages: false,
                    guidance: "Keep watching and engaging in the same niche around any upload. Early videos get extra weight, so uploads must stay coherent with the niche."
                ),
            ]
        case .threads, .facebook:
            []
        }
    }

    /// Where each app shows the signed-in account's handle, so the agent can
    /// confirm it is driving the persona's account before any engagement.
    static func accountLocation(for platform: Platform) -> String {
        switch platform {
        case .tikTok:
            "Tap the Profile tab at the bottom right. The @username appears under the display name at the top of the profile."
        case .instagram:
            "Tap the profile avatar tab at the bottom right. The username appears at the top of the profile page."
        case .x:
            "Tap the account avatar at the top left to open the side menu. The display name and @handle appear at the top of the menu."
        case .youtube:
            "Tap the You tab at the bottom right. The channel name and @handle appear at the top of the page."
        case .threads, .facebook:
            "Open the profile tab and read the username shown at the top of the profile."
        }
    }

    static func phaseIndex(for platform: Platform, day: Int) -> Int {
        let plans = phases(for: platform)
        return plans.firstIndex(where: { $0.contains(day: day) }) ?? max(plans.count - 1, 0)
    }
}

/// Form values become the explicit brief for the phone warm-up workflow.
struct WarmUpConfiguration: Sendable {
    var profileName = ""
    var profileHandle = ""
    var profileNarrative = ""
    var platform: Platform = .tikTok
    var phaseIndex = 0
    var sessionMinutes = 20
    var itemsToView = 10
    var niche = ""

    var hasProfile: Bool { !trim(profileName).isEmpty }

    /// The handle as the app displays it: no surrounding whitespace or leading @.
    var normalizedHandle: String {
        var handle = trim(profileHandle)
        while handle.hasPrefix("@") { handle.removeFirst() }
        return handle
    }

    var hasHandle: Bool { !normalizedHandle.isEmpty }

    /// The first thing the agent does: prove the phone is signed in as this
    /// persona. Any other account, or a signed-out app, stops the run.
    var accountCheck: String {
        """
        Account check, before anything else: open \(platform.displayName). \(WarmUpPlaybook.accountLocation(for: platform)) Confirm the signed-in handle is exactly @\(normalizedHandle) (ignore letter case). If the app shows a sign-in or sign-up screen, an account picker, no handle, or any other handle, STOP and request input; do not browse, like, follow, comment, search, or post. Never sign in, sign out, switch accounts, or enter credentials. Only after confirming the handle, return to the feed and start the session.
        """
    }

    var phase: WarmUpPhasePlan {
        let plans = WarmUpPlaybook.phases(for: platform)
        guard !plans.isEmpty else {
            return WarmUpPhasePlan(
                title: "Days 1–3", firstDay: 1, lastDay: nil,
                activities: [.scrollFeed, .like],
                maxLikes: 5, maxFollows: 0, maxComments: 0, maxPosts: 0,
                allowsDirectMessages: false, guidance: ""
            )
        }
        return plans[min(max(phaseIndex, 0), plans.count - 1)]
    }

    var brief: String {
        let plan = phase
        var lines: [String] = [
            "Persona: \(trim(profileName)) (@\(normalizedHandle)). \(trim(profileNarrative))",
            "Platform: \(platform.displayName)",
            trim(accountCheck),
            "Warm-up phase: \(plan.title) of a new account. Niche: \(trim(niche)). Stay on content in this niche so the algorithm learns it.",
            "Session: about \(sessionMinutes) minutes. Stop after viewing \(itemsToView) videos or posts, or when the time is up — whichever comes first.",
            "Allowed actions and daily-look caps for this session: like at most \(plan.maxLikes), follow at most \(plan.maxFollows), comment at most \(plan.maxComments)\(plan.allowsPosting ? ", post at most \(plan.maxPosts)" : "").",
        ]
        if platform == .tikTok {
            lines.append("TikTok: choose a top-three search suggestion, then open a top-row video. Watch it to completion, swipe up once, and verify the next video starts. Repeat within session limits.")
        }
        if !plan.guidance.isEmpty {
            lines.append("Phase guidance: \(plan.guidance)")
        }
        var prohibitions: [String] = []
        if !plan.allowsPosting { prohibitions.append("posting or uploading anything") }
        if !plan.allowsDirectMessages { prohibitions.append("direct messages") }
        prohibitions.append("links")
        if !prohibitions.isEmpty {
            lines.append("Do NOT do any of the following this phase: \(prohibitions.joined(separator: ", ")).")
        }
        if platform == .tikTok {
            lines.append("Watch each video to completion before swiping up once to the next. Pause between actions. Never mass-like or mass-follow.")
        } else {
            lines.append("Behave like a person: vary watch time, skip some content quickly, and pause between actions instead of repeating one action rapidly. Never mass-like or mass-follow.")
        }
        return lines.joined(separator: "\n")
    }

    var validationMessage: String? {
        if !hasProfile { return "Choose an agent profile." }
        if !hasHandle { return "Add the persona’s handle so the signed-in account can be verified." }
        if trim(niche).isEmpty { return "Add the niche this persona browses." }
        if DeviceWorkflow.warmUp.goal(details: brief).count > DevicePromptPlanner.maximumPromptLength {
            return "Shorten the warm-up details before running."
        }
        return nil
    }

    private func trim(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
