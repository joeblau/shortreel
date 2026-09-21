import Foundation

// From apple/: swiftc -swift-version 6 ShortReel/Models/*.swift ShortReel/Services/DeviceHost.swift
// ShortReel/Services/DevicePrompts/{WarmUpScript,WarmUpPlaybook,DeviceWorkflow,DevicePromptPlanner,DevicePromptPlan}.swift Tests/WarmUpConfigurationTests.swift
// -o /tmp/shortreel-warmup-tests && /tmp/shortreel-warmup-tests
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
        var generatedPersonality = valid()
        generatedPersonality.profileNarrative = String(repeating: "a", count: 1_000)
        try expect(generatedPersonality.validationMessage == nil, "Playback guidance crowds out a typical generated personality")
        print("Warm-up configuration tests passed (6 scenarios)")
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
