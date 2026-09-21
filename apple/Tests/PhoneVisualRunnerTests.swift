import Foundation
import CoreGraphics
import ImageIO

// swiftc -swift-version 6 ShortReel/Services/DevicePrompts/{WarmUpScript,PhonePlaybackTracker,PhoneSubmissionGuard,PhoneSubmissionCheckpoint,DevicePromptPlan,DevicePromptPlanner,DeviceWorkflow,PhoneVisionTypes,PhoneVisualRunner,WarmUpStateTree}.swift Tests/PhoneVisualRunnerTests.swift -o /tmp/shortreel-visual-runner-tests
@main @MainActor
enum PhoneVisualRunnerTests {
    private enum TestError: LocalizedError {
        case failed(String)
        var errorDescription: String? {
            switch self { case .failed(let message): message }
        }
    }

    @MainActor private final class Gate {
        private(set) var waiting = false
        private var continuation: CheckedContinuation<Void, Never>?

        func wait() async {
            waiting = true
            await withCheckedContinuation { continuation = $0 }
        }

        func release() {
            continuation?.resume()
            continuation = nil
        }
    }

    static func main() async throws {
        try await observationOrderAndVerification()
        try await rejectUnfreshFrames()
        try await rejectChangedSourceAndDuplicateID()
        try await rejectMalformedImages()
        try await stopRepeatedInput()
        try await rejectMalformedDecisions()
        try await retryNamesTheRejection()
        try await requireClarification()
        try await disconnectBeforeDispatch()
        try await cancelledModelCannotDispatch()
        try await cancellationStopsRemainingInput()
        try await decisionAndDurationLimits()
        try await failedInputStopsLoop()
        try await stopNearlyIdenticalTapLoop()
        try await appSwitcherDiagnostic()
        try await tiktokPlaybackReview()
        try await scriptedWatchLoop()
        try await scriptedLongVideoSkip()
        try await stateTreeBypassesModel()
        try await stateTreeDisconnectBlocksInput()
        try await scriptDeadline()
        try await submissionJournalPrecedesInput()
        try await submissionStorageFailureBlocksInput()
        try await submissionCannotBeRepeatedDuringVerification()
        print("Phone visual runner tests passed (24 scenarios)")
    }

    private static func submissionJournalPrecedesInput() async throws {
        var decisions = 0
        var states: [PhoneSubmissionCheckpoint.State] = []
        var inputs = 0
        let runner = PhoneVisualRunner(capture: { after in try frame(after: after) },
            decide: { goal, _, _ in
                decisions += 1
                switch decisions {
                case 1: return .finished("Matching account visible")
                case 2: return .finished("Requested text is ready in the composer")
                case 3: return .action(.tap(0.8, 0.2), reason: "Visible Post button")
                case 4:
                    try expect(goal.contains("Verify"), "Submit did not immediately transition to verification")
                    return .wait(seconds: 0.25, reason: "Upload in progress")
                default: return .finished("Published post visible under the correct account")
                }
            }, perform: { _ in
                try expect(states.last == .submitting, "Input was sent before the durable submission checkpoint")
                inputs += 1
            }, blockedReason: { nil }, validateSubmissionAction: { _, _, _ in })
        let script = WarmUpScript(network: .x, activity: .post, itemLimit: 1, duration: 30)
        _ = try await runner.run(goal: "Post supplied text", workflow: .warmUp, warmUpScript: script,
            onSubmissionCheckpoint: { states.append($0.state) }, onProgress: { _ in }, onStep: { _ in })
        try expect(inputs == 1 && states == [.preparing, .submitting, .confirmed], "Incorrect submission lifecycle")
    }

    private static func submissionStorageFailureBlocksInput() async throws {
        var decisions = 0
        var inputs = 0
        let runner = PhoneVisualRunner(capture: { after in try frame(after: after) },
            decide: { _, _, _ in
                decisions += 1
                return decisions < 3 ? .finished("Verified preparation") : .action(.tap(0.8, 0.2), reason: "Post")
            }, perform: { _ in inputs += 1 }, blockedReason: { nil }, validateSubmissionAction: { _, _, _ in })
        do {
            _ = try await runner.run(goal: "Post supplied text", workflow: .warmUp,
                warmUpScript: WarmUpScript(network: .x, activity: .post, itemLimit: 1, duration: 30),
                onSubmissionCheckpoint: { checkpoint in
                    if checkpoint.state == .submitting { throw TestError.failed("Disk unavailable") }
                }, onProgress: { _ in }, onStep: { _ in })
            throw TestError.failed("Ignored submission journal failure")
        } catch let error as TestError {
            try expect(error.localizedDescription == "Disk unavailable", "Wrong journal error")
        }
        try expect(inputs == 0, "Publishing continued without a saved checkpoint")
    }

    private static func submissionCannotBeRepeatedDuringVerification() async throws {
        var decisions = 0
        var inputs = 0
        var states: [PhoneSubmissionCheckpoint.State] = []
        let runner = PhoneVisualRunner(capture: { after in try frame(after: after) },
            decide: { _, _, _ in
                decisions += 1
                return decisions < 3 ? .finished("Verified preparation") : .action(.tap(0.8, 0.2), reason: "Try Post")
            }, perform: { _ in inputs += 1 }, blockedReason: { nil }, validateSubmissionAction: { _, _, _ in })
        do {
            _ = try await runner.run(goal: "Post supplied text", workflow: .warmUp,
                warmUpScript: WarmUpScript(network: .x, activity: .post, itemLimit: 1, duration: 30),
                onSubmissionCheckpoint: { states.append($0.state) }, onProgress: { _ in }, onStep: { _ in })
            throw TestError.failed("Allowed another tap during verification")
        } catch is PhonePromptPlanningError { }
        try expect(inputs == 1 && states == [.preparing, .submitting, .uncertain], "Ambiguous publish was retried or not flagged")
    }

    private static func scriptedWatchLoop() async throws {
        let script = WarmUpScript(network: .tikTok, activity: .watch, itemLimit: 2, duration: 30)
        let decisions: [(String, PhoneVisionDecision)] = [
            ("Verify account", .finished("Matching handle visible")),
            ("Search niche", .finished("Two-word query and suggestions visible")),
            ("Choose search result", .finished("Video grid visible")),
            ("Find video with >10K hearts", .finished("First video playing with 25K hearts visible")),
            ("Watch to completion", .wait(seconds: 0.25, reason: "Still playing")),
            ("Watch to completion", .finished("First video visibly restarted")),
            ("Next video", .action(.timedDrag(0.5, 0.8, 0.5, 0.2, duration: 0.4, pressDuration: 0, holdDuration: 0), reason: "Advance after verified completion")),
            ("Next video", .wait(seconds: 0.25, reason: "Transition loading")),
            ("Next video", .finished("Different video now playing")),
            ("Watch to completion", .finished("Second video ending verified")),
        ]
        var index = 0
        var inputs: [PhonePromptAction] = []
        var progress: [String] = []
        let runner = PhoneVisualRunner(capture: { after in try frame(after: after) },
            decide: { goal, _, _ in
                try expect(index < decisions.count, "Script continued after its item limit")
                let (title, decision) = decisions[index]
                try expect(goal.contains(": \(title)."), "Wrong active script step: \(title)")
                if index == 7 { try expect(goal.contains("already sent"), "Advance input not retained") }
                index += 1
                return decision
            }, perform: { inputs.append($0) }, blockedReason: { nil })
        let result = try await runner.run(goal: "Platform: TikTok", workflow: .warmUp, warmUpScript: script,
            onScriptProgress: { progress.append($0) }, onProgress: { _ in }, onStep: { _ in })
        try expect(index == decisions.count && inputs == [.swipe(.up)], "Not exactly one swipe between two completed videos")
        try expect(result.contains("completed") && progress.last?.contains("2/2 viewed") == true,
            "Script progress did not reach the item limit")
    }

    private static func scriptDeadline() async throws {
        var inputs = 0
        let runner = PhoneVisualRunner(capture: { after in try frame(after: after) },
            decide: { _, _, _ in
                try await Task.sleep(for: .seconds(1))
                return .action(.swipe(.up), reason: "Too late")
            }, perform: { _ in inputs += 1 }, blockedReason: { nil })
        let script = WarmUpScript(network: .tikTok, activity: .watch, itemLimit: 2, duration: 0.05)
        let result = try await runner.run(goal: "Platform: TikTok", workflow: .warmUp, warmUpScript: script,
            onProgress: { _ in }, onStep: { _ in })
        try expect(inputs == 0 && result.contains("time limit"), "Script sent input after its deadline")
        do {
            _ = try await runner.run(goal: "Publish provided content", workflow: .warmUp,
                warmUpScript: WarmUpScript(network: .x, activity: .post, itemLimit: 1, duration: 0.05),
                onProgress: { _ in }, onStep: { _ in })
            throw TestError.failed("Incomplete publication timed out as success")
        } catch is PhonePromptPlanningError { }
        try expect(inputs == 0, "Expired publication sent input")
    }

    private static func stateTreeBypassesModel() async throws {
        func text(_ label: String, _ x: Double, _ y: Double) -> PhonePlaybackTracker.TextRegion {
            .init(text: label, confidence: 1, bounds: CGRect(x: x, y: y, width: 0.1, height: 0.02))
        }
        let navigation = [text("Home", 0.05, 0.94), text("Inbox", 0.65, 0.94), text("Profile", 0.85, 0.94)]
        let feed = navigation + [text("For You", 0.5, 0.07), text("Following", 0.25, 0.07)]
        let profile = navigation + [text("@test", 0.3, 0.2), text("Edit profile", 0.2, 0.4),
                                    text("Followers", 0.4, 0.3), text("Following", 0.2, 0.3)]
        let results = [text("Search", 0.8, 0.08), text("Top", 0.1, 0.16), text("Videos", 0.3, 0.16), text("Users", 0.6, 0.16)]
        let player = [text("Search", 0.8, 0.08), text("Add comment...", 0.1, 0.93),
                      text("A caption for this video", 0.05, 0.83),
                      text("64.3K", 0.9, 0.5), text("783", 0.9, 0.6), text("1463", 0.9, 0.7)]
        let screens = [feed, profile, profile, [], results, player, player, player, player, player]
        var observations = 0
        var modelCalls = 0
        var inputs: [PhonePromptAction] = []
        var logged: [PhoneVisionStep] = []
        let runner = PhoneVisualRunner(capture: { after in try frame(after: after) }, decide: { goal, _, _ in
            modelCalls += 1
            try expect(goal.contains("STATE TREE:"), "Fallback lost current page context")
            if goal.contains("Advance sent: true") {
                return .finished("Different creator and caption verify the next video")
            }
            return .finished("Current milestone verified from the screenshot")
        }, perform: { inputs.append($0) }, blockedReason: { nil }, readText: { frame, platform in
            try! expect(observations < screens.count, "State tree exceeded expected route length")
            let regions = screens[observations]
            observations += 1
            return .init(sourceID: frame.sourceID, capturedAt: frame.capturedAt, platform: platform, regions: regions)
        })
        let result = try await runner.run(goal: "Account check: Verify exactly @test, ignoring case.", workflow: .warmUp,
            warmUpScript: .init(network: .tikTok, activity: .watch, itemLimit: 2, duration: 60),
            onProgress: { _ in }, onStep: { logged.append($0) })
        try expect(observations == 10 && modelCalls == 5, "Known pages failed to bypass model calls")
        try expect(inputs.count == 3 && inputs.last == .swipe(.up), "Navigation or advance was duplicated")
        try expect(logged.filter { $0.decisionSource == "state tree" }.count == 5, "Local decisions were not recorded")
        try expect(result.contains("completed"), "State tree did not finish the viewing goal")
    }

    private static func stateTreeDisconnectBlocksInput() async throws {
        var blocked = false
        var inputs = 0
        let runner = PhoneVisualRunner(capture: { after in try frame(after: after) },
            decide: { _, _, _ in throw TestError.failed("Recognized feed unexpectedly invoked model") },
            perform: { _ in inputs += 1 }, blockedReason: { blocked ? "Disconnected" : nil },
            readText: { frame, platform in
                let labels: [(String, Double, Double)] = [("Home", 0.05, 0.94), ("Inbox", 0.65, 0.94),
                    ("Profile", 0.85, 0.94), ("For You", 0.5, 0.07), ("Following", 0.25, 0.07)]
                return .init(sourceID: frame.sourceID, capturedAt: frame.capturedAt, platform: platform,
                    regions: labels.map { .init(text: $0.0, confidence: 1,
                        bounds: CGRect(x: $0.1, y: $0.2, width: 0.1, height: 0.02)) })
            })
        do {
            _ = try await runner.run(goal: "Watch", workflow: .warmUp,
                warmUpScript: .init(network: .tikTok, activity: .watch, itemLimit: 1, duration: 60),
                onProgress: { if $0.hasPrefix("Following the feed") { blocked = true } }, onStep: { _ in })
            throw TestError.failed("Disconnected local route continued")
        } catch PhoneVisionError.unavailable { }
        try expect(inputs == 0, "Local route bypassed availability checks")
    }

    private static func scriptedLongVideoSkip() async throws {
        var decisions = 0
        var inputs: [PhonePromptAction] = []
        var checkpoints: [WarmUpScriptCheckpoint] = []
        let runner = PhoneVisualRunner(capture: { after in try frame(after: after) },
            decide: { goal, _, _ in
                decisions += 1
                switch decisions {
                case 1...4: return .finished("Account, search, and qualifying starting video verified")
                case 5:
                    try expect(goal.contains("LONGER THAN 1:00"), "Duration exception never reached the planner")
                    return .action(.drag(0.5, 0.8, 0.5, 0.2), reason: "No readable total; same playing video advanced about 10% in 8 seconds, suggesting 80 seconds; skip without counting")
                case 6:
                    try expect(goal.contains("already sent"), "Skip must verify the new item before more input")
                    return .finished("Different video is now playing")
                default: return .finished("New 30-second video completed")
                }
            }, perform: { inputs.append($0) }, blockedReason: { nil })
        _ = try await runner.run(goal: "Watch one video", workflow: .warmUp,
            warmUpScript: WarmUpScript(network: .tikTok, activity: .watch, itemLimit: 1, duration: 60),
            onScriptCheckpoint: { checkpoints.append($0) }, onProgress: { _ in }, onStep: { _ in })
        try expect(inputs == [.swipe(.up)] && checkpoints.contains { $0.advanceSent && $0.itemsCompleted == 0 },
            "Long video was counted or skip dispatched more than once")
        try expect(checkpoints.last?.itemsCompleted == 1 && checkpoints.last?.isComplete == true,
            "Short video after the skip did not complete the viewing target")
    }

    private static func tiktokPlaybackReview() async throws {
        var inputs: [PhonePromptAction] = []
        var reviews = 0
        var captures = 0
        var firstFrameID: UUID?
        let runner = PhoneVisualRunner(capture: { after in
            captures += 1
            let image = try frame(after: after, shade: captures.isMultiple(of: 2) ? 0 : 1)
            if firstFrameID == nil { firstFrameID = image.id }
            return image
        }, decide: { _, _, history in
            if history.last?.playbackReviewRequested == true {
                reviews += 1
                try expect(history.last?.playbackStartFrame?.id == firstFrameID,
                    "Playback review lost the first waiting frame")
                try expect(history.last!.executionFeedback.contains("PLAYBACK COMPLETION REVIEW"),
                    "Playback review request never reaches the planner")
                if reviews == 1 {
                    try expect(inputs.isEmpty, "Advanced before completion was observed")
                    return .wait(seconds: 0.25, reason: "Still playing the first time")
                }
                return .action(.swipe(.up), reason: "Same video visibly restarted; advance after completion")
            }
            if history.last?.input == .swipe(.up) {
                try expect(history.last?.playbackStartFrame == nil, "Old video observation survived the swipe")
                return .wait(seconds: 0.25, reason: "A different video is now playing")
            }
            if inputs.count == 1 {
                try expect(history.last?.playbackStartFrame?.id != firstFrameID,
                    "Next video reused the previous video's watching start")
                return .finished("Next video verified; requested test limit reached")
            }
            return .wait(seconds: 0.25, reason: "Waiting for video completion")
        }, perform: { inputs.append($0) }, blockedReason: { nil })
        _ = try await runner.run(goal: "Warm Up\nPlatform: TikTok\nWatch within session limits", workflow: .warmUp,
            onProgress: { _ in }, onStep: {
                precondition($0.playbackStartFrame == nil, "UI history retained a full playback image")
            })
        try expect(reviews == 2 && inputs == [.swipe(.up)],
            "Completion review must continue an unfinished video, then send exactly one upward swipe")
    }

    private static func appSwitcherDiagnostic() async throws {
        for succeeds in [true, false] {
            var inputs: [PhonePromptAction] = []
            var observations = 0
            let runner = PhoneVisualRunner(capture: { after in try frame(after: after) },
                decide: { _, _, _ in throw TestError.failed("Diagnostic must not call the action planner") },
                perform: { inputs.append($0) }, blockedReason: { nil }, inspect: { _ in
                    observations += 1
                    let state: PhoneScreenObservation.State = succeeds ? .appSwitcher : .homeEditing
                    return .init(state: state, appCardsVisible: state == .appSwitcher, evidence: "Visible interface")
                })
            if succeeds {
                let result = try await runner.testAppSwitcher(onProgress: { _ in }, onStep: { _ in })
                try expect(result.contains("verified"), "Diagnostic lost successful verification")
            } else {
                try await expectFailure(.unavailable) {
                    try await runner.testAppSwitcher(onProgress: { _ in }, onStep: { _ in })
                }
            }
            try expect(inputs == [.press(.appSwitcher)], "Diagnostic repeated or dismissed apps")
            try expect(observations == 1, "Diagnostic accepted input dispatch as success")
        }
    }

    private static func observationOrderAndVerification() async throws {
        var events: [String] = []
        var frames: [PhoneScreenFrame] = []
        var steps: [PhoneVisionStep] = []
        var completedAt: Date?
        var decisionCount = 0
        let runner = PhoneVisualRunner(capture: { after in
            if let completedAt { try expect(after >= completedAt, "Capture requested a frame from before input completion") }
            events.append("capture")
            let next = try frame(after: after, shade: Double(frames.count) / 4)
            frames.append(next)
            return next
        }, decide: { goal, frame, history in
            try expect(goal == "Open settings", "The goal changed between decisions")
            try expect(frame == frames.last, "The model received the wrong frame")
            try expect(history.map(\.id) == steps.map(\.id), "The model did not receive the completed step history")
            if let latest = history.last {
                try expect(latest.afterFrame == frame && latest.beforeFrame != nil, "Missing before/after evidence")
                try expect(latest.screenChanged == true, "Changed screen was not reported")
                try expect(latest.input != nil, "Exact executed action was lost")
            }
            events.append("decide")
            decisionCount += 1
            switch decisionCount {
            case 1: return .action(.home, reason: "Show the Home screen.")
            case 2: return .action(.tap(0.25, 0.75), reason: "Settings is visible here.")
            default:
                try expect(frames.count == 3, "Finished without a post-action screen")
                return .finished("Settings is open on the phone.")
            }
        }, perform: { action in
            events.append("perform")
            try expect(action == .home || action == .tap(0.25, 0.75), "Unexpected input")
            completedAt = Date()
        }, blockedReason: { nil })
        let result = try await runner.run(goal: "Open settings", onProgress: { _ in }, onStep: { steps.append($0) })
        try expect(result == "Settings is open on the phone.", "The final screen result was lost")
        try expect(events == ["capture", "decide", "perform", "capture", "decide", "perform", "capture", "decide"], "Input ran without observing a fresh screen")
        try expect(steps.count == 2 && steps.map(\.number) == [1, 2], "Step log is incomplete")
        try expect(steps.allSatisfy { $0.beforeFrame == nil && $0.afterFrame == nil }, "UI history retained run screenshots")
        try expect(steps[0].capturedAt == frames[0].capturedAt && steps[1].capturedAt == frames[1].capturedAt, "Step logs lost source-frame timestamps")
        try expect(steps[1].detail == "Settings is visible here.", "The model's action reason was lost")
    }

    private static func rejectUnfreshFrames() async throws {
        for offset in [-121.0, -0.01, 0.0, 600.0] {
            var decisions = 0
            var inputs = 0
            let runner = PhoneVisualRunner(capture: { after in
                let valid = try frame(after: after)
                return copy(valid, capturedAt: after.addingTimeInterval(offset))
            }, decide: { _, _, _ in
                decisions += 1
                return .finished("Done")
            }, perform: { _ in inputs += 1 }, blockedReason: { nil })
            try await expectFailure(.stale) { try await runner.run(goal: "Open settings", onProgress: { _ in }, onStep: { _ in }) }
            try expect(decisions == 0 && inputs == 0, "A stale/future frame reached the model or driver")
        }
    }

    private static func rejectChangedSourceAndDuplicateID() async throws {
        for changeSource in [true, false] {
            let firstID = UUID()
            var captures = 0
            var decisions = 0
            var inputs = 0
            let runner = PhoneVisualRunner(capture: { after in
                captures += 1
                return try frame(after: after, id: changeSource ? UUID() : firstID,
                    source: changeSource && captures > 1 ? "Other Phone" : "Phone")
            }, decide: { _, _, _ in
                decisions += 1
                return .action(.home, reason: "Show the Home screen.")
            }, perform: { _ in inputs += 1 }, blockedReason: { nil })
            try await expectFailure(changeSource ? .source : .stale) {
                try await runner.run(goal: "Open settings", onProgress: { _ in }, onStep: { _ in })
            }
            try expect(inputs == 1 && decisions == 1 && captures == 2, "An invalid second frame was used for another input")
        }
    }

    private static func rejectMalformedImages() async throws {
        for invalidCase in 0..<6 {
            var decisions = 0
            let runner = PhoneVisualRunner(capture: { after in
                let good = try frame(after: after)
                switch invalidCase {
                case 0: return copy(good, data: Data())
                case 1: return copy(good, data: Data([0xFF, 0xD8, 0x01, 0x02, 0xFF, 0xD9]))
                case 2: return copy(good, width: 0)
                case 3: return copy(good, width: 999_999)
                case 4: return copy(good, width: good.pixelWidth + 1)
                default: return copy(good, source: "  ")
                }
            }, decide: { _, _, _ in
                decisions += 1
                return .finished("Done")
            }, perform: { _ in throw TestError.failed("Malformed image reached input driver") }, blockedReason: { nil })
            try await expectFailure(.unavailable) { try await runner.run(goal: "Open settings", onProgress: { _ in }, onStep: { _ in }) }
            try expect(decisions == 0, "Malformed image reached the model")
        }
    }

    private static func stopRepeatedInput() async throws {
        for waiting in [false, true] {
            var decisions = 0
            var inputs = 0
            var steps = 0
            let runner = PhoneVisualRunner(capture: { try frame(after: $0) }, decide: { _, _, history in
                if let previous = history.last {
                    try expect(previous.screenChanged == false, "Unchanged input did not reach the planner as execution feedback")
                }
                decisions += 1
                // Different wording must not bypass the repeated input guard.
                return waiting ? .wait(seconds: 0.25, reason: "Wait \(decisions)") : .action(.tap(0.5, 0.5), reason: "Tap \(decisions)")
            }, perform: { _ in inputs += 1 }, blockedReason: { nil })
            try await expectFailure(.unavailable) {
                try await runner.run(goal: "Open settings", onProgress: { _ in }, onStep: { _ in steps += 1 })
            }
            try expect(decisions == 3 && steps == 2, "Repeated unchanged screens did not stop at the third decision")
            try expect(inputs == (waiting ? 0 : 2), "The third blind input was dispatched")
        }
        // Identical actions remain allowed when their input screen has changed.
        var decisions = 0
        var inputs = 0
        let changing = PhoneVisualRunner(capture: { try frame(after: $0, shade: Double(decisions) / 5) }, decide: { _, _, _ in
            decisions += 1
            return decisions <= 3 ? .action(.swipe(.up), reason: "More content is below.") : .finished("The item is visible.")
        }, perform: { _ in inputs += 1 }, blockedReason: { nil })
        _ = try await changing.run(goal: "Find the item", onProgress: { _ in }, onStep: { _ in })
        try expect(inputs == 3, "Changing screens were incorrectly treated as a blind loop")
    }

    private static func rejectMalformedDecisions() async throws {
        let badDecisions: [PhoneVisionDecision] = [
            .action(.tap(.nan, 0), reason: "Tap"),
            .action(.drag(0, 0, 2, 0), reason: "Drag"),
            .action(.openApp("Settings"), reason: "Open Settings"),
            .action(.search("Settings"), reason: "Search"),
            .action(.typeText(String(repeating: "a", count: 101)), reason: "Type"),
            .action(.home, reason: ""), .action(.typeText("😀"), reason: "Type"),
            .wait(seconds: .infinity, reason: "Wait"), .wait(seconds: 4, reason: "Wait"),
            .finished(""), .needsInput(""),
        ]
        for decision in badDecisions {
            var inputs = 0
            let runner = PhoneVisualRunner(capture: { try frame(after: $0) }, decide: { _, _, _ in decision },
                perform: { _ in inputs += 1 }, blockedReason: { nil })
            try await expectFailure(.invalid) { try await runner.run(goal: "Open settings", onProgress: { _ in }, onStep: { _ in }) }
            try expect(inputs == 0, "Malformed decision sent input")
        }
    }

    /// One malformed answer is retried with the rejection spelled out, so the
    /// model can fix the unit instead of repeating the same mistake.
    private static func retryNamesTheRejection() async throws {
        var asks = 0
        var inputs: [PhonePromptAction] = []
        let runner = PhoneVisualRunner(capture: { try frame(after: $0) }, decide: { goal, _, _ in
            asks += 1
            switch asks {
            case 1:
                try expect(!goal.contains("PREVIOUS RESPONSE REJECTED"), "First ask already carried a rejection")
                return .action(.tap(1.5, 0.5), reason: "Tap")
            case 2:
                try expect(goal.contains("PREVIOUS RESPONSE REJECTED") && goal.contains("0 to 1"),
                    "Retry did not tell the model why its answer was rejected")
                return .action(.tap(0.5, 0.5), reason: "Tap")
            default:
                return .finished("Done")
            }
        }, perform: { inputs.append($0) }, blockedReason: { nil })
        _ = try await runner.run(goal: "Open settings", onProgress: { _ in }, onStep: { _ in })
        try expect(inputs == [.tap(0.5, 0.5)], "Corrected decision was not the one dispatched")
    }

    private static func requireClarification() async throws {
        let runner = PhoneVisualRunner(capture: { try frame(after: $0) }, decide: { _, _, _ in
            .needsInput("Which account should I choose?")
        }, perform: { _ in throw TestError.failed("Clarification dispatched input") }, blockedReason: { nil })
        do {
            _ = try await runner.run(goal: "Choose my account", onProgress: { _ in }, onStep: { _ in })
            throw TestError.failed("Clarification was reported as success")
        } catch let error as PhonePromptPlanningError {
            try expect(error.localizedDescription == "Which account should I choose?", "Clarification message was lost")
        }
    }

    private static func disconnectBeforeDispatch() async throws {
        for disconnectInStep in [true, false] {
            var connected = true
            var inputs = 0
            let runner = PhoneVisualRunner(capture: { try frame(after: $0) }, decide: { _, _, _ in
                if !disconnectInStep { connected = false }
                return .action(.home, reason: "Show the Home screen.")
            }, perform: { _ in inputs += 1 }, blockedReason: { connected ? nil : "Phone disconnected" })
            try await expectFailure(.unavailable) {
                try await runner.run(goal: "Open settings", onProgress: { _ in }, onStep: { _ in connected = false })
            }
            try expect(inputs == 0, "A disconnected phone received input")
        }
    }

    private static func cancelledModelCannotDispatch() async throws {
        let gate = Gate()
        var inputs = 0
        let runner = PhoneVisualRunner(capture: { try frame(after: $0) }, decide: { _, _, _ in
            await gate.wait() // Deliberately ignores cancellation until released.
            return .action(.home, reason: "Show the Home screen.")
        }, perform: { _ in inputs += 1 }, blockedReason: { nil })
        let task = Task { try await runner.run(goal: "Open settings", onProgress: { _ in }, onStep: { _ in }) }
        try await waitUntil { gate.waiting }
        task.cancel()
        do {
            _ = try await task.value
            throw TestError.failed("Cancelled model run returned success")
        } catch is CancellationError { }
        gate.release()
        await Task.yield()
        try expect(inputs == 0, "A late cancelled model result dispatched input")
    }

    private static func cancellationStopsRemainingInput() async throws {
        let gate = Gate()
        var inputs = 0
        var captures = 0
        let runner = PhoneVisualRunner(capture: {
            captures += 1
            return try frame(after: $0)
        }, decide: { _, _, _ in .action(.home, reason: "Show the Home screen.") }, perform: { _ in
            inputs += 1
            await gate.wait()
        }, blockedReason: { nil })
        let task = Task { try await runner.run(goal: "Open settings", onProgress: { _ in }, onStep: { _ in }) }
        try await waitUntil { gate.waiting }
        task.cancel()
        do {
            _ = try await task.value
            throw TestError.failed("Cancelled input run returned success")
        } catch is CancellationError { }
        gate.release()
        await Task.yield()
        try expect(inputs == 1 && captures == 1, "Cancelled input continued to another screen/action")
    }

    private static func decisionAndDurationLimits() async throws {
        var decisions = 0
        var inputs = 0
        let bounded = PhoneVisualRunner(capture: { try frame(after: $0, shade: Double(decisions) / 5) }, decide: { _, _, _ in
            decisions += 1
            return .action(.home, reason: "Show the Home screen.")
        }, perform: { _ in inputs += 1 }, blockedReason: { nil }, maximumSteps: 2)
        try await expectFailure(.limit) { try await bounded.run(goal: "Open settings", onProgress: { _ in }, onStep: { _ in }) }
        try expect(decisions == 2 && inputs == 2, "The decision limit was exceeded")

        let gate = Gate()
        var lateInputs = 0
        let timed = PhoneVisualRunner(capture: { try frame(after: $0) }, decide: { _, _, _ in
            await gate.wait()
            return .action(.home, reason: "Show the Home screen.")
        }, perform: { _ in lateInputs += 1 }, blockedReason: { nil }, maximumDuration: 0.05)
        try await expectFailure(.limit) { try await timed.run(goal: "Open settings", onProgress: { _ in }, onStep: { _ in }) }
        try expect(gate.waiting, "Timed test never entered the pending model")
        gate.release()
        await Task.yield()
        try expect(lateInputs == 0, "An expired model result dispatched input")
    }

    private static func failedInputStopsLoop() async throws {
        var captures = 0
        var inputs = 0
        let runner = PhoneVisualRunner(capture: {
            captures += 1
            return try frame(after: $0)
        }, decide: { _, _, _ in .action(.home, reason: "Show the Home screen.") }, perform: { _ in
            inputs += 1
            throw PhoneVisionError.unavailable("Bluetooth write failed")
        }, blockedReason: { nil })
        try await expectFailure(.unavailable) { try await runner.run(goal: "Open settings", onProgress: { _ in }, onStep: { _ in }) }
        try expect(captures == 1 && inputs == 1, "The loop continued after failed input")
    }

    private static func stopNearlyIdenticalTapLoop() async throws {
        var decisions = 0, inputs = 0
        let runner = PhoneVisualRunner(capture: { try frame(after: $0, shade: 0.5 + Double(decisions) * 0.003) }, decide: { _, _, _ in
            decisions += 1
            return .action(.tap(0.4 + Double(decisions) * 0.002, 0.6), reason: "Try the same icon again")
        }, perform: { _ in inputs += 1 }, blockedReason: { nil })
        try await expectFailure(.unavailable) { try await runner.run(goal: "Open Safari", onProgress: { _ in }, onStep: { _ in }) }
        try expect(inputs == 2, "JPEG noise or coordinate jitter bypassed the stalled-input guard")
    }

    private static func frame(after: Date, id: UUID = UUID(), source: String = "Phone", shade: Double = 0) throws -> PhoneScreenFrame {
        let width = 8
        let height = 12
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: colorSpace, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
            throw TestError.failed("Could not create image fixture")
        }
        context.setFillColor(red: shade, green: shade, blue: shade, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        guard let image = context.makeImage() else { throw TestError.failed("Could not create image fixture") }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil) else {
            throw TestError.failed("Could not create JPEG fixture")
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw TestError.failed("Could not encode JPEG fixture") }
        let timestamp = max(Date(), after.addingTimeInterval(0.000_001))
        return .init(id: id, capturedAt: timestamp, pixelWidth: width, pixelHeight: height, jpegData: data as Data, cgImage: image, sourceID: source)
    }

    private static func copy(_ frame: PhoneScreenFrame, capturedAt: Date? = nil, data: Data? = nil, width: Int? = nil, source: String? = nil) -> PhoneScreenFrame {
        .init(id: frame.id, capturedAt: capturedAt ?? frame.capturedAt, pixelWidth: width ?? frame.pixelWidth,
            pixelHeight: frame.pixelHeight, jpegData: data ?? frame.jpegData, cgImage: frame.cgImage, sourceID: source ?? frame.sourceID)
    }

    private enum ExpectedError { case stale, source, unavailable, invalid, limit }

    private static func expectFailure(_ expected: ExpectedError, operation: () async throws -> String) async throws {
        do {
            _ = try await operation()
            throw TestError.failed("Expected visual request to fail: \(expected)")
        } catch let error as PhoneVisionError {
            let matches: Bool = switch (expected, error) {
            case (.stale, .staleFrame), (.source, .sourceChanged), (.unavailable, .unavailable),
                 (.invalid, .invalidDecision), (.limit, .limitReached): true
            default: false
            }
            try expect(matches, "Unexpected visual failure: \(error)")
        } catch is PhonePromptPlanningError {
            try expect(expected == .invalid, "Unexpected planning failure")
        }
    }

    private static func waitUntil(_ predicate: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(2)
        while !predicate() {
            guard ContinuousClock.now < deadline else { throw TestError.failed("Timed out waiting for test state") }
            try await Task.sleep(for: .milliseconds(1))
        }
    }

    private static func expect(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        guard try condition() else { throw TestError.failed(message) }
    }
}
