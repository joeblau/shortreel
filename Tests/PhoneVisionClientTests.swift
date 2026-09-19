import Foundation

// Compile with DevicePromptPlan.swift, DevicePromptPlanner.swift,
// PhoneVisionTypes.swift, and PhoneVisionClient.swift. No model or phone is used.
@main
enum PhoneVisionClientTests {
    @MainActor
    static func main() throws {
        let photos = PhoneVisionClient.GroundingTarget(id: 0, text: "Photos", x: 0.74, y: 0.83)
        let trash = PhoneVisionClient.GroundingTarget(id: 1, text: "Trash", x: 0.25, y: 0.12)

        // OCR geometry replaces every model-supplied coordinate for a label.
        let grounded = try PhoneVisionClient.groundedPointerDecision(
            proposed: .tap(0.1, 0.2), targetID: 0, targets: [photos],
            goal: "Open Photos", reason: "Tap the visible Photos label."
        )
        expect(grounded == .action(.tap(0.74, 0.83), reason: "Tap the visible Photos label."), "Tap must use OCR coordinates")

        for (goal, point) in [
            ("Tap the gear icon", PhonePromptAction.tap(0.5, 0.5)),
            ("Tap the blue rectangle", .tap(0.8, 0.81)),
            ("Open Safari", .tap(0.4, 0.3)),
            ("Do not tap 50%, 40%", .tap(0.5, 0.4)),
            ("Tap 50%, 40% then go home", .tap(0.5, 0.4)),
            ("Tap 50%, 40%", .tap(0.5, 0.41)),
        ] {
            try expectNeedsInput(.init(proposed: point, goal: goal, reason: "Tap the requested point."))
        }

        let explicit = try PhoneVisionClient.groundedPointerDecision(
            proposed: .tap(0.5, 0.4), targetID: -1, targets: [],
            goal: "Tap 50%, 40%", reason: "Tap the coordinates supplied by the user."
        )
        expect(explicit == .action(.tap(0.5, 0.4), reason: "Tap the coordinates supplied by the user."), "Exact user coordinates must work")

        try expectNeedsInput(.init(proposed: .tap(0.2, 0.3), targetID: 9, targets: [photos], goal: "Open Photos", reason: "Tap Photos."))
        try expectNeedsInput(.init(proposed: .tap(0.2, 0.3), targetID: 0, targets: [photos], goal: "Open Settings", reason: "Tap Settings."))
        try expectNeedsInput(.init(proposed: .tap(0.2, 0.3), targetID: 0, targets: [photos], goal: "Open Photos", reason: "Photos is not visible."))
        let duplicate = PhoneVisionClient.GroundingTarget(id: 2, text: "photos", x: 0.1, y: 0.2)
        try expectNeedsInput(.init(proposed: .tap(0.2, 0.3), targetID: 0, targets: [photos, duplicate], goal: "Open Photos", reason: "Tap Photos."))
        let reusedID = PhoneVisionClient.GroundingTarget(id: 0, text: "Settings", x: 0.1, y: 0.2)
        try expectNeedsInput(.init(proposed: .tap(0.2, 0.3), targetID: 0, targets: [photos, reusedID], goal: "Open Photos", reason: "Tap Photos."))

        let drag = try PhoneVisionClient.groundedPointerDecision(
            proposed: .drag(0, 0, 1, 1), targetID: 0, endTargetID: 1,
            targets: [photos, trash], goal: "Drag Photos to Trash", reason: "Drag Photos onto Trash."
        )
        expect(drag == .action(.drag(0.74, 0.83, 0.25, 0.12), reason: "Drag Photos onto Trash."), "Drag must ground both ends")
        try expectNeedsInput(.init(proposed: .drag(0, 0, 1, 1), targetID: 0, targets: [photos], goal: "Drag Photos to the corner", reason: "Drag Photos to the corner."))
        try expectNeedsInput(.init(proposed: .drag(0, 0, 1, 1), targetID: 0, endTargetID: 0, targets: [photos], goal: "Drag Photos", reason: "Drag Photos."))
        try expectNeedsInput(.init(proposed: .drag(0, 0, 1, 1), goal: "Drag the icon", reason: "Drag the icon."))

        // The public action validator is still enforced after OCR resolution.
        let invalid = PhoneVisionClient.GroundingTarget(id: 0, text: "Photos", x: .nan, y: 0.4)
        do {
            _ = try PhoneVisionClient.groundedPointerDecision(proposed: .tap(0, 0), targetID: 0, targets: [invalid], goal: "Open Photos", reason: "Tap Photos.")
            fatalError("Invalid OCR geometry must not become input")
        } catch is PhonePromptPlanningError {}

        print("PhoneVisionClient grounding tests passed")
    }

    struct Case {
        let proposed: PhonePromptAction
        var targetID = -1
        var endTargetID = -1
        var targets: [PhoneVisionClient.GroundingTarget] = []
        let goal: String
        let reason: String
    }

    @MainActor
    static func expectNeedsInput(_ test: Case) throws {
        let result = try PhoneVisionClient.groundedPointerDecision(
            proposed: test.proposed, targetID: test.targetID, endTargetID: test.endTargetID,
            targets: test.targets, goal: test.goal, reason: test.reason
        )
        guard case .needsInput = result else { fatalError("Expected no input for \(test.goal), got \(result)") }
    }

    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else { fatalError(message) }
    }
}
