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
                        try rejects { try cursor.validate(.swipe(.up)) }
                        try rejects { try cursor.validate(.drag(0.5, 0.8, 0.5, 0.2)) }
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
        try expect(script.identifier == "warmup.tiktok.watch" && script.version == 1, "Unstable versioned identity")
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
            _ = try WarmUpScriptRegistry.script(network: .youtube, activity: .watch, itemLimit: 1, duration: 300, version: 2)
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

}
