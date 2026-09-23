import Foundation

@main
enum WarmUpConfigurationTests {
    enum Failure: Error { case assertion(String) }

    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw Failure.assertion(message) }
    }

    static func main() throws {
        try accountCheckLeadsTheBrief()
        try handleIsRequiredAndNormalized()
        try everyPlatformNamesWhereTheHandleIs()
        try goalRequiresTheCheckBeforeEngagement()
        try activityLimits()
        try dailySessionFollowsTheSchedule()
        var generatedPersonality = valid()
        generatedPersonality.profileNarrative = String(repeating: "a", count: 1_000)
        try expect(generatedPersonality.validationMessage == nil, "Playback guidance crowds out a typical generated personality")
        print("Warm-up configuration tests passed (7 scenarios)")
    }

    static func activityLimits() throws {
        for platform in WarmUpPlaybook.platforms {
            var config = valid()
            config.platform = platform
            config.activity = .comment
            if config.phase.maxComments == 0 {
                try expect(config.validationMessage?.contains("Comments are unavailable") == true, "Early comments allowed")
            }
            config.phaseIndex = 1
            try expect(config.validationMessage == nil && config.script?.itemLimit == 1, "Comment script should consume one item")
            config.activity = .post
            try expect(config.validationMessage?.contains("Describe the post") == true, "Post has no content instructions")
            config.contentInstructions = "Use the existing street photography video from the Photos album Shoot 1."
            try expect(config.validationMessage == nil, "Valid post was rejected")
            config.phaseIndex = 0
            try expect(config.validationMessage?.contains("Posting is unavailable") == true, "Early posting allowed")
        }
        var config = valid()
        config.platform = .facebook
        try expect(config.validationMessage != nil && config.script == nil, "Unsupported platform silently falls back")
        config = valid()
        config.sessionMinutes = 0
        try expect(config.validationMessage != nil, "Zero duration accepted")
    }

    static func dailySessionFollowsTheSchedule() throws {
        let base = valid()
        for day in 1...3 {
            let session = WarmUpDailySession.build(base, day: day, postInstructions: "Use the Shoot 1 video.")
            try expect(session.runs.map(\.activity) == [.watch] && session.notes.isEmpty,
                "TikTok day \(day) should be watch only")
        }
        for day in 4...7 {
            let session = WarmUpDailySession.build(base, day: day, postInstructions: "Use the Shoot 1 video.")
            try expect(session.runs.map(\.activity) == [.watch, .comment, .comment, .comment, .post],
                "TikTok day \(day) should watch, comment, then post")
            try expect(session.runs[0].script.likeLimit == 15 && session.runs[0].script.followLimit == 0
                && session.runs.dropFirst().allSatisfy { $0.script.likeLimit == 0 }, "Days 4–7 like during Watch only, without follows")
        }
        let later = WarmUpDailySession.build(base, day: 12)
        try expect(later.runs.first?.activity == .watch && later.runs.filter { $0.activity == .post }.isEmpty
            && later.notes.contains { $0.hasPrefix("Post:") } && later.runs[0].script.followLimit == 12,
            "Week 2+ adds follows, and skips posting without instructions")
        for day in 1...3 {
            try expect(WarmUpDailySession.build(base, day: day).runs[0].script.engages == false, "Days 1–3 engaged")
        }
        try expect(WarmUpDailySession.build(base, day: 12, postInstructions: "Use the Shoot 2 video.").runs
            .filter { $0.activity == .post }.count == WarmUpDailySession.maximumPostsPerDay, "More than one post per day")
        try expect(later.runs.allSatisfy { $0.brief.contains("@maya.shoots") && $0.brief.contains("Phase: Week 2+") },
            "Daily runs lost the persona handle or phase")
        var incomplete = base
        incomplete.niche = ""
        let blocked = WarmUpDailySession.build(incomplete, day: 5)
        try expect(blocked.runs.isEmpty && blocked.notes.contains { $0.hasPrefix("Watch:") }, "Invalid configuration queued runs")
    }

    static func valid() -> WarmUpConfiguration {
        var configuration = WarmUpConfiguration()
        configuration.profileName = "Maya Chen"
        configuration.profileHandle = "maya.shoots"
        configuration.profileNarrative = "Street photographer."
        configuration.platform = .tikTok
        configuration.niche = "street photography"
        return configuration
    }

    static func accountCheckLeadsTheBrief() throws {
        let configuration = valid()
        try expect(configuration.validationMessage == nil, "Rejected a complete warm-up")
        let lines = configuration.brief.components(separatedBy: "\n")
        try expect(lines.count > 3 && lines[2].hasPrefix("Account check, before anything else: open TikTok."),
            "Account check is not the first instruction after persona and platform")
        let check = lines[2]
        try expect(check.contains("exactly @maya.shoots"), "Account check does not name the persona handle")
        try expect(check.contains("Profile tab"), "Account check lacks the TikTok profile location")
        try expect(check.contains("STOP and request input"), "Mismatched account does not stop the run")
        try expect(check.contains("Never sign in, sign out, switch accounts, or enter credentials"),
            "Account check permits changing the signed-in account")
        try expect(lines.firstIndex { $0.hasPrefix("Session:") }! > 2, "Session limits precede the account check")
        try expect(DeviceWorkflow.warmUp.goal(details: configuration.brief).count < DevicePromptPlanner.maximumPromptLength,
            "Account check pushed the brief past the model goal limit")
    }

    static func handleIsRequiredAndNormalized() throws {
        var configuration = valid()
        configuration.profileHandle = "  "
        try expect(configuration.validationMessage?.contains("handle") == true, "Ran a warm-up with no handle to verify")
        configuration.profileHandle = " @@Maya.Shoots "
        try expect(configuration.normalizedHandle == "Maya.Shoots", "Handle kept its @ prefix or whitespace")
        try expect(configuration.validationMessage == nil, "Rejected an @-prefixed handle")
        try expect(configuration.brief.contains("(@Maya.Shoots)") && configuration.brief.contains("exactly @Maya.Shoots")
            && !configuration.brief.contains("@@"), "Brief shows a doubled @ or lost the handle")
    }

    static func everyPlatformNamesWhereTheHandleIs() throws {
        for platform in Platform.allCases {
            var configuration = valid()
            configuration.platform = platform
            let location = WarmUpPlaybook.accountLocation(for: platform)
            try expect(location.lowercased().contains("tap") || location.lowercased().contains("open"),
                "\(platform.displayName) has no navigation hint for the signed-in handle")
            try expect(configuration.brief.contains("open \(platform.displayName). \(location)"),
                "\(platform.displayName) brief does not use its account location")
        }
    }

    static func goalRequiresTheCheckBeforeEngagement() throws {
        let goal = DeviceWorkflow.warmUp.goal(details: valid().brief)
        let rule = goal.range(of: "Start with the brief's account check")
        let session = goal.range(of: "Then follow the specified persona")
        try expect(rule != nil && session != nil && rule!.lowerBound < session!.lowerBound,
            "Workflow goal does not put the account check ahead of the session")
        try expect(goal.contains("never sign in, sign out, switch accounts, or enter credentials"),
            "Workflow goal allows changing the signed-in account")
    }
}
