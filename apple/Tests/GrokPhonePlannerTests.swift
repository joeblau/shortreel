import Foundation

@main
enum GrokPhonePlannerTests {
    @MainActor
    static func main() throws {
        let photos = PhoneVisionClient.GroundingTarget(id: 2, text: "Photos", x: 0.74, y: 0.83)
        let base: [String: Any] = [
            "kind": "home", "evidence": "The phone shows Settings.",
            "explanation": "Return to the Home screen.", "targetID": -1, "endTargetID": -1,
            "x": 0.0, "y": 0.0, "endX": 0.0, "endY": 0.0,
            "text": "", "direction": "", "key": "", "seconds": 0.0, "visualTargetDescription": ""
        ]
        func result(_ patch: [String: Any] = [:], goal: String = "Open Photos", targets: [PhoneVisionClient.GroundingTarget] = []) throws -> PhoneVisionDecision {
            try GrokPhonePlanner.decodeResult(envelope(base.merging(patch) { _, new in new }), goal: goal, targets: targets)
        }
        expectThrows { _ = try result() }
        for key in PhoneKey.allCases {
            expect(try result(["kind": "press", "key": key.rawValue]) == .action(.press(key), reason: "Return to the Home screen."), "Supported keys must decode")
        }
        let tap: [String: Any] = ["kind": "tap", "targetID": 2, "x": 0.1, "y": 0.2, "explanation": "Tap Photos."]
        expect(try result(tap, targets: [photos]) == .action(.tap(0.74, 0.83), reason: "Tap Photos."), "OCR must replace model coordinates")
        try expectNeedsInput(result(tap))
        try expectNeedsInput(result(tap.merging(["targetID": -1]) { _, new in new }))
        try expectNeedsInput(result(tap.merging(["explanation": "Tap Settings."]) { _, new in new }, targets: [photos]))
        let duplicate = PhoneVisionClient.GroundingTarget(id: 3, text: "photos", x: 0.2, y: 0.1)
        try expectNeedsInput(result(tap, targets: [photos, duplicate]))
        expect(try result(["kind": "tap", "x": 0.5, "y": 0.4], goal: "Tap 50%, 40%") == .action(.tap(0.5, 0.4), reason: "Return to the Home screen."), "Exact user coordinates must remain available")

        let visual: [String: Any] = [
            "kind": "tap", "targetID": -1, "x": 0.375, "y": 0.94,
            "evidence": "A blue compass icon is visible in the bottom dock.",
            "explanation": "Open Safari using its visible dock icon.",
            "visualTargetDescription": "Blue compass icon, second from the left in the bottom dock."
        ]
        expect(try result(visual, goal: "Open Safari") == .action(.tap(0.375, 0.94), reason: "Open Safari using its visible dock icon. Visible target: Blue compass icon, second from the left in the bottom dock."), "An identified unlabeled control may use Grok's image coordinates")
        try expectNeedsInput(result(visual.merging(["visualTargetDescription": " \n "]) { _, new in new }, goal: "Open Safari"))
        for patch: [String: Any] in [["x": -0.001], ["y": 1.001], ["x": "NaN"], ["evidence": ""], ["explanation": ""], ["visualTargetDescription": NSNull()], ["visualTargetDescription": 1], ["visualTargetDescription": String(repeating: "x", count: 201)]] {
            expectThrows { _ = try result(visual.merging(patch) { _, new in new }) }
        }
        for doubt in ["The icon is not visible.", "I cannot locate the control.", "I'm guessing where to tap.", "This might be Safari."] {
            try expectNeedsInput(result(visual.merging(["visualTargetDescription": doubt]) { _, new in new }))
        }
        let navigationEvidence = visual.merging(["evidence": "The Safari window is not visible; its blue compass dock icon is visible."]) { _, new in new }
        guard case .action(.tap, _) = try result(navigationEvidence) else { fatalError("An absent destination must not block tapping a clearly identified navigation control") }
        try expectNeedsInput(result(visual, goal: "Tap 50%, 40%"))
        expect(try result(visual.merging(["x": 0.5, "y": 0.4]) { _, new in new }, goal: "Tap 50%, 40%") == .action(.tap(0.5, 0.4), reason: "Open Safari using its visible dock icon."), "Visual descriptions must not change explicit user coordinates")
        try expectNeedsInput(result(visual.merging(["x": 0.5, "y": 0.4, "targetID": 2]) { _, new in new }, goal: "Tap 50%, 40%", targets: [photos]))
        for patch: [String: Any] in [["targetID": 59], ["targetID": 2]] {
            try expectNeedsInput(result(visual.merging(patch) { _, new in new }, targets: [photos]))
        }
        try expectNeedsInput(result(tap.merging(["visualTargetDescription": "Photos icon"]) { _, new in new }, targets: [photos, duplicate]))
        expect(try result(tap.merging(["visualTargetDescription": "Photos icon"]) { _, new in new }, targets: [photos]) == .action(.tap(0.74, 0.83), reason: "Tap Photos."), "A supplied OCR ID still owns the tap coordinates")

        for patch: [String: Any] in [
            ["kind": "openApp"], ["kind": "press", "key": "shell"],
            ["kind": "swipe", "direction": "diagonal"], ["kind": "wait", "seconds": 0.1],
            ["kind": "wait", "seconds": 3.1], ["x": -0.01], ["y": 1.01], ["targetID": 60],
            ["targetID": true], ["kind": "typeText", "text": "🙂"],
            ["kind": "typeText", "text": String(repeating: "a", count: 101)],
            ["kind": "finished", "evidence": "  "], ["explanation": ""], ["extra": "ignored command"]
        ] {
            expectThrows { _ = try result(patch) }
        }
        var missing = base
        missing.removeValue(forKey: "evidence")
        expectThrows { _ = try GrokPhonePlanner.decodeResult(envelope(missing), goal: "Open Photos", targets: []) }
        for patch: [String: Any] in [["stopReason": "max_turns"], ["num_turns": 2], ["num_turns": true], ["structuredOutput": NSNull()]] {
            expectThrows { _ = try GrokPhonePlanner.decodeResult(envelope(base, patch: patch), goal: "Open Photos", targets: []) }
        }
        expectThrows { _ = try GrokPhonePlanner.decodeResult(Data("not JSON".utf8), goal: "Open Photos", targets: []) }

        let empty: [String: Any] = ["plugins": [], "hooks": [], "mcpServers": [], "lspServers": [], "projectInstructions": []]
        try GrokPhonePlanner.validateIsolation(JSONSerialization.data(withJSONObject: empty))
        for field in empty.keys {
            var active = empty
            active[field] = [[field == "plugins" ? "enabled" : "disabled": field == "plugins"]]
            expectThrows { try GrokPhonePlanner.validateIsolation(JSONSerialization.data(withJSONObject: active)) }
            active[field] = [[:]]
            expectThrows { try GrokPhonePlanner.validateIsolation(JSONSerialization.data(withJSONObject: active)) }
            active[field] = [[field == "plugins" ? "enabled" : "disabled": field != "plugins"]]
            try GrokPhonePlanner.validateIsolation(JSONSerialization.data(withJSONObject: active))
            active.removeValue(forKey: field)
            expectThrows { try GrokPhonePlanner.validateIsolation(JSONSerialization.data(withJSONObject: active)) }
        }
        print("GrokPhonePlanner decoder and isolation tests passed")
    }

    static func envelope(_ payload: [String: Any], patch: [String: Any] = [:]) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["stopReason": "end_turn", "num_turns": 1, "structuredOutput": payload].merging(patch) { _, new in new })
    }
    static func expect(_ value: @autoclosure () throws -> Bool, _ message: String) rethrows {
        guard try value() else { fatalError(message) }
    }
    static func expectThrows(_ body: () throws -> Void) {
        do { try body() } catch { return }
        fatalError("Expected rejection")
    }
    static func expectNeedsInput(_ value: @autoclosure () throws -> PhoneVisionDecision) throws {
        guard case .needsInput = try value() else { fatalError("Ungrounded input must not execute") }
    }
}
