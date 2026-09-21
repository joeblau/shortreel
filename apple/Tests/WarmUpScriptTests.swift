import Foundation

// From apple/: swiftc -swift-version 6 ShortReel/Services/DevicePrompts/{WarmUpScript,DevicePromptPlan,DevicePromptPlanner}.swift Tests/WarmUpScriptTests.swift -o /tmp/shortreel-script-tests && /tmp/shortreel-script-tests
@main
enum WarmUpScriptTests {
    enum Failure: Error { case assertion(String) }
    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw Failure.assertion(message) }
    }
    static func rejects(_ operation: () throws -> Void) throws {
        do { try operation() } catch is PhonePromptPlanningError { return }
        throw Failure.assertion("Accepted an invalid script transition")
    }
    static func main() throws {
        for network in WarmUpScript.Network.allCases {
            for activity in WarmUpActivity.allCases {
                let script = WarmUpScript(network: network, activity: activity, itemLimit: activity == .watch ? 3 : 1, duration: 300)
                var cursor = WarmUpScriptCursor(script: script)
                try expect(cursor.step.id == .account, "Account check must precede every activity")
                try expect(script.steps.map(\.id).contains(.suggestion) == (network == .tikTok && activity != .post),
                    "Only TikTok browsing uses search suggestions")
                var advances = 0
                var completions = 0
                while !cursor.isComplete && completions < 30 {
                    if cursor.step.id == .consume {
                        try rejects { try cursor.validate(.swipe(.up), observedVideoDuration: 60) }
                        try rejects { try cursor.validate(.drag(0.5, 0.8, 0.5, 0.2), observedVideoDuration: 60) }
                    }
                    if cursor.step.id == .advance {
                        try rejects { var premature = cursor; try premature.finishStep() }
                        try cursor.validate(.swipe(.up))
                        cursor.didPerform(.swipe(.up))
                        try rejects { try cursor.validate(.swipe(.up)) }
                        try expect(cursor.goal("brief").contains("already sent"), "Planner can repeat the advance gesture")
                        advances += 1
                    }
                    if cursor.step.id == .submit {
                        try rejects { var premature = cursor; try premature.finishStep() }
                        try rejects { try cursor.validate(.typeText("duplicate")) }
                        try cursor.validate(.tap(0.5, 0.5))
                        cursor.didPerform(.tap(0.5, 0.5))
                        try expect(cursor.step.id == .verifySubmission && cursor.submissionSent,
                            "Submission did not immediately enter verification")
                        try expect(cursor.checkpoint.submissionSent, "Checkpoint lost submission boundary")
                        try rejects { try cursor.validate(.tap(0.5, 0.5)) }
                        try rejects { try cursor.validate(.swipe(.up)) }
                    } else {
                        try cursor.finishStep()
                    }
                    completions += 1
                }
                try expect(cursor.isComplete, "Script failed to finish")
                try expect(cursor.itemsCompleted == (activity == .watch ? 3 : activity == .comment ? 1 : 0),
                    "Wrong completed-item count for \(network) \(activity)")
                try expect(advances == (activity == .watch ? 2 : 0), "Swiped past final item or during publishing")
                try expect(script.steps.filter { $0.id == .submit }.count == (activity == .watch ? 0 : 1),
                    "Watch must never publish; Comment/Post publish at most once")
            }
        }
        try contracts()
        try savedSnapshots()
        try startingVideoVersions()
        try durationSkipping()
        try coordinateAdvance()
        print("Warm-up script tests passed (12 platform/activity combinations, version contracts, snapshots, submission boundaries)")
    }
    static func rejectsContract(_ operation: () throws -> Void) throws {
        do { try operation() } catch { return }
        throw Failure.assertion("Accepted an invalid script contract")
    }

    static func contracts() throws {
        try expect(WarmUpScriptRegistry.definitions.count == 12, "Missing platform/activity registry entry")
        try expect(Set(WarmUpScriptRegistry.definitions.map(\.identifier)).count == 12, "Duplicate script identifiers")
        let script = try WarmUpScriptRegistry.script(network: .tikTok, activity: .watch, itemLimit: 3, duration: 300)
        try expect(script.identifier == "warmup.tiktok.watch" && script.version == 5, "Unstable versioned identity")
        try expect(script.retryPolicy.maximumPreparationAttempts == 1
            && script.retryPolicy.maximumSubmissionAttempts == 1
            && !script.retryPolicy.retriesUncertainSubmission
            && !script.retryPolicy.resumesInterruptedRun, "Unsafe retry contract")
        for limit in [-1, 0, 51] {
            try rejectsContract {
                _ = try WarmUpScriptRegistry.script(network: .tikTok, activity: .watch, itemLimit: limit, duration: 300)
            }
        }
        for activity in [WarmUpActivity.comment, .post] {
            try rejectsContract {
                _ = try WarmUpScriptRegistry.script(network: .x, activity: activity, itemLimit: 2, duration: 300)
            }
        }
        for duration in [0, -1, 3_601, Double.infinity, Double.nan] {
            try rejectsContract {
                _ = try WarmUpScriptRegistry.script(network: .instagram, activity: .watch, itemLimit: 1, duration: duration)
            }
        }
        try rejectsContract {
            _ = try WarmUpScriptRegistry.script(network: .youtube, activity: .watch, itemLimit: 1, duration: 300, version: 99)
        }
        // A direct initializer cannot bypass validation at the cursor boundary.
        let invalid = WarmUpScript(network: .x, activity: .post, itemLimit: 1, duration: 300, version: 2)
        try rejectsContract { try WarmUpScriptCursor(script: invalid).validate(.tap(0.5, 0.5)) }
    }

    static func savedSnapshots() throws {
        let script = try WarmUpScriptRegistry.script(network: .instagram, activity: .comment, itemLimit: 1, duration: 600)
        let envelope = try WarmUpScriptEnvelope(script: script)
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        let data = try encoder.encode(envelope)
        let restored = try decoder.decode(WarmUpScriptEnvelope.self, from: data)
        try expect(restored == envelope, "Saved script changed during round trip")
        var json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        json["schemaVersion"] = 2
        try rejectsContract { _ = try decoder.decode(WarmUpScriptEnvelope.self, from: JSONSerialization.data(withJSONObject: json)) }
        json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        var savedScript = json["script"] as! [String: Any]
        savedScript["version"] = 99
        json["script"] = savedScript
        try rejectsContract { _ = try decoder.decode(WarmUpScriptEnvelope.self, from: JSONSerialization.data(withJSONObject: json)) }
        savedScript["version"] = 1
        savedScript["network"] = "Facebook"
        json["script"] = savedScript
        try rejectsContract { _ = try decoder.decode(WarmUpScriptEnvelope.self, from: JSONSerialization.data(withJSONObject: json)) }
        savedScript["network"] = "Instagram"
        savedScript["activity"] = "massLike"
        json["script"] = savedScript
        try rejectsContract { _ = try decoder.decode(WarmUpScriptEnvelope.self, from: JSONSerialization.data(withJSONObject: json)) }
        json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        var steps = json["steps"] as! [[String: Any]]
        steps[0]["instruction"] = "Skip account verification"
        json["steps"] = steps
        try rejectsContract { _ = try decoder.decode(WarmUpScriptEnvelope.self, from: JSONSerialization.data(withJSONObject: json)) }
        json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        var policy = json["retryPolicy"] as! [String: Any]
        policy["maximumSubmissionAttempts"] = 2
        json["retryPolicy"] = policy
        try rejectsContract { _ = try decoder.decode(WarmUpScriptEnvelope.self, from: JSONSerialization.data(withJSONObject: json)) }

        var cursor = WarmUpScriptCursor(script: script)
        while cursor.step.id != .submit { try cursor.finishStep() }
        cursor.didPerform(.tap(0.5, 0.5))
        let checkpoint = try decoder.decode(WarmUpScriptCheckpoint.self, from: encoder.encode(cursor.checkpoint))
        try expect(checkpoint == cursor.checkpoint && checkpoint.submissionSent && !checkpoint.isComplete,
            "Unconfirmed submission checkpoint was lost")
        try cursor.finishStep()
        try expect(cursor.checkpoint.isComplete, "Completed state missing from checkpoint")
        try rejects { try cursor.validate(.tap(0.5, 0.5)) }
    }

    static func coordinateAdvance() throws {
        let script = WarmUpScript(network: .tikTok, activity: .watch, itemLimit: 2, duration: 300)
        let gestures: [PhonePromptAction] = [
            .swipe(.up), .drag(0.5, 0.8, 0.5, 0.2),
            .timedDrag(0.5, 0.75, 0.5, 0.25, duration: 0.4, pressDuration: 0, holdDuration: 0)
        ]
        for gesture in gestures {
            var cursor = WarmUpScriptCursor(script: script)
            while cursor.step.id != .advance { try cursor.finishStep() }
            for wrong in [PhonePromptAction.swipe(.down), .tap(0.5, 0.5),
                          .drag(0.5, 0.2, 0.5, 0.8), .drag(0.8, 0.5, 0.2, 0.5),
                          .drag(0.5, 0.99, 0.5, 0.2), .drag(0.5, 0.6, 0.5, 0.59),
                          .timedDrag(0.5, 0.8, 0.5, 0.2, duration: 0.4, pressDuration: 1, holdDuration: 1)] {
                try rejects { try cursor.validate(wrong) }
            }
            try cursor.validate(gesture)
            try expect(cursor.normalizedAction(gesture) == .swipe(.up), "Feed gesture not normalized")
            cursor.didPerform(gesture)
            try expect(cursor.advanceSent && cursor.itemsCompleted == 1, "Advance checkpoint was not recorded")
            for duplicate in gestures { try rejects { try cursor.validate(duplicate) } }
            try cursor.finishStep()
            try expect(cursor.step.id == .consume && !cursor.advanceSent, "Next item was not verified")
        }
    }

    static func durationSkipping() throws {
        for network in [WarmUpScript.Network.tikTok, .instagram, .youtube] {
            let script = try WarmUpScriptRegistry.script(network: network, activity: .watch, itemLimit: 1, duration: 300)
            try expect(script.maximumVideoDurationSeconds == 60, "Missing one-minute limit")
            var cursor = WarmUpScriptCursor(script: script)
            while cursor.step.id != .consume { try cursor.finishStep() }
            for seconds in [30, 59, 60] {
                try rejects { try cursor.validate(.swipe(.up), observedVideoDuration: seconds) }
            }
            try expect(script.allowsEstimatedDurationSkip, "New Watch scripts must allow estimated duration")
            try cursor.validate(.swipe(.up), observedVideoDuration: nil)
            try cursor.validate(.swipe(.up), observedVideoDuration: 61)
            cursor.didPerform(.swipe(.up))
            try expect(cursor.step.id == .advance && cursor.advanceSent && cursor.itemsCompleted == 0,
                "Skipped video counted as watched or bypassed verification")
            try rejects { try cursor.validate(.swipe(.up), observedVideoDuration: 180) }
            try cursor.finishStep()
            try expect(cursor.step.id == .consume && cursor.itemsCompleted == 0, "Skip did not resume watching")
            try cursor.finishStep()
            try expect(cursor.isComplete && cursor.itemsCompleted == 1, "Completed video was not counted after skip")
            let previousEstimated = WarmUpScript(network: network, activity: .watch, itemLimit: 1, duration: 300,
                version: network == .tikTok ? 4 : 3)
            try expect(previousEstimated.maximumVideoDurationSeconds == 120 && previousEstimated.allowsEstimatedDurationSkip,
                "Saved two-minute estimated policy changed")
            let previousEnvelope = try WarmUpScriptEnvelope(script: previousEstimated)
            let previousRestored = try JSONDecoder().decode(WarmUpScriptEnvelope.self, from: JSONEncoder().encode(previousEnvelope))
            try expect(previousRestored == previousEnvelope, "Previous estimated duration snapshot no longer decodes")
            let exactOnly = WarmUpScript(network: network, activity: .watch, itemLimit: 1, duration: 300,
                version: network == .tikTok ? 3 : 2)
            try expect(!exactOnly.allowsEstimatedDurationSkip && exactOnly.maximumVideoDurationSeconds == 120,
                "Previous duration policy changed")
            let exactEnvelope = try WarmUpScriptEnvelope(script: exactOnly)
            let exactRestored = try JSONDecoder().decode(WarmUpScriptEnvelope.self, from: JSONEncoder().encode(exactEnvelope))
            try expect(exactRestored == exactEnvelope, "Previous duration snapshot no longer decodes")
            let old = WarmUpScript(network: network, activity: .watch, itemLimit: 1, duration: 300,
                version: network == .tikTok ? 2 : 1)
            try expect(old.maximumVideoDurationSeconds == nil, "Saved scripts silently changed duration policy")
            let oldEnvelope = try WarmUpScriptEnvelope(script: old)
            let restored = try JSONDecoder().decode(WarmUpScriptEnvelope.self, from: JSONEncoder().encode(oldEnvelope))
            try expect(restored == oldEnvelope, "Existing saved scripts no longer decode")
        }
    }

    static func startingVideoVersions() throws {
        for activity in [WarmUpActivity.watch, .comment] {
            let latest = try WarmUpScriptRegistry.script(network: .tikTok, activity: activity, itemLimit: 1, duration: 300, version: 2)
            let legacy = try WarmUpScriptRegistry.script(network: .tikTok, activity: activity, itemLimit: 1, duration: 300, version: 1)
            try expect(latest.version == 2 && latest.requiresPopularStartingVideo, "New TikTok runs did not select the updated contract")
            try expect(!legacy.requiresPopularStartingVideo, "Old queued runs silently changed their selection rule")
            let oldEnvelope = try WarmUpScriptEnvelope(script: legacy)
            let restored = try JSONDecoder().decode(WarmUpScriptEnvelope.self, from: JSONEncoder().encode(oldEnvelope))
            try expect(restored == oldEnvelope && restored.steps.first { $0.id == .open }?.title == "Open video",
                "Legacy journal snapshots can no longer be loaded")
            try expect(latest.steps.filter { $0.id != .open } == legacy.steps.filter { $0.id != .open },
                "Starting-video selection unexpectedly changed later viewing or publication steps")
            let latestEnvelope = try WarmUpScriptEnvelope(script: latest)
            let newRestored = try JSONDecoder().decode(WarmUpScriptEnvelope.self, from: JSONEncoder().encode(latestEnvelope))
            try expect(newRestored == latestEnvelope, "New selection contract did not survive persistence")
        }
        for definition in WarmUpScriptRegistry.definitions {
            let expected = WarmUpScript.currentVersion(network: definition.network, activity: definition.activity)
            try expect(definition.version == expected, "Version changed for an unrelated script")
        }
    }

}
