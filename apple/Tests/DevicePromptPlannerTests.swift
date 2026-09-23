import Foundation

@main
enum DevicePromptPlannerTests {
    static func main() throws {
        try expect("please open Safari", [.openApp("Safari")])
        try expect("Could you please launch Settings", [.openApp("Settings")])
        try expect("Open App Store", [.openApp("App Store")])
        try expect("open the app YouTube Music", [.openApp("YouTube Music")])
        try expect("open the tiktok app", [.openApp("tiktok")])
        try expect("Please launch the YouTube Music app.", [.openApp("YouTube Music")])
        try expect("open Cash App", [.openApp("Cash App")])
        try expect("open \"The Weather App\"", [.openApp("The Weather App")])
        try expect("launch \"Days and Nights\"", [.openApp("Days and Nights")])
        try expect("open Safari then go home", [.openApp("Safari"), .home])
        try expect("Open Safari, then scroll down", [.openApp("Safari"), .swipe(.up)])
        try expect("type \"Hello,\" then press enter", [.typeText("Hello,"), .press(.enter)])
        try expect("go to the home screen; swipe UP\npress return", [.home, .swipe(.up), .press(.enter)])
        try expect("go home\n\nswipe down", [.home, .swipe(.down)])
        try expect("tap the center", [.tap(0.5, 0.5)])
        try expect("click in the centre of the screen", [.tap(0.5, 0.5)])
        try expect("tap at (0.25, 1)", [.tap(0.25, 1)])
        try expect("tap 0%, 100%", [.tap(0, 1)])
        try expect("tap 50%, 25%", [.tap(0.5, 0.25)])
        try expect("tap .5, 0", [.tap(0.5, 0)])
        try expect("scroll down", [.swipe(.up)])
        try expect("scroll up", [.swipe(.down)])
        try expect("scroll left", [.swipe(.right)])
        try expect("scroll right", [.swipe(.left)])
        try expect("swipe left 3 times", Array(repeating: .swipe(.left), count: 3))
        try expect("press the tab key twice", [.press(.tab), .press(.tab)])
        try expect("press escape; press backspace", [.press(.escape), .press(.backspace)])

        try expect("type \"Hello; then World!\" then press return", [.typeText("Hello; then World!"), .press(.enter)])
        try expect("type \"  Spaces & Case  \"", [.typeText("  Spaces & Case  ")])
        try expect("type \"Line 1\nLine 2\"", [.typeText("Line 1\nLine 2")])
        try expect("type 'I'm ready; then wait'", [.typeText("I'm ready; then wait")])
        try expect("type “Hello!”", [.typeText("Hello!")])
        try expect(#"type "Say \"Hello\"; then \\wait" then press enter"#, [.typeText(#"Say "Hello"; then \wait"#), .press(.enter)])
        try expect("type \"hello 3 times\"", [.typeText("hello 3 times")])
        try expect("type Don't delete this.", [.typeText("Don't delete this.")])
        try expect("search for Cats & Dogs!", [.search("Cats & Dogs!")])
        try expect("search for \"cats then dogs; More\"", [.search("cats then dogs; More")])

        let invalid = [
            "", "   ", "don't open Safari", "do not swipe up", "never press enter",
            "open Safari then tap Like", "go home; send a message to Joe",
            "open Safari and send a message", "open Safari and dance",
            "open Safari send a message", "open Safari, type hello", "search for",
            "open Safari but don't tap anything", "open Safari to buy a ticket",
            "search for cats and send a message", "type hello and press enter",
            "tap the Like button", "delete Photos", "buy an app", "post hello",
            "swipe up unless there is a video", "press return and open Safari",
            "type \"hello\" and send it", "type \"hello\" press enter",
            "type \"unclosed", "type 'unclosed", "type \"\"", "type \"   \"",
            "tap 50, 50", "tap -0.1, 0.5", "tap 0.5, 1.1", "tap 101%, 0%",
            "tap 50%, 0.5", "tap NaN, 0", "tap infinity, 0", "tap (0.5, 0.5",
            "tap 0.5, 0.5)", "swipe up 0 times", "swipe up 6 times",
            "swipe up 999999999999999999999 times", "open Safari then", ";go home",
            "go home;;swipe up", "go home;", "then go home",
            "type café", "type \"😀\"", "type \"a\tb\"", "open \"Safari\nSettings\"",
            "search \"first\nsecond\"",
        ]
        for prompt in invalid { try expectRejection(prompt) }
        try expectRejection("type \"" + String(repeating: "a", count: DevicePromptPlanner.maximumTextLength + 1) + "\"")
        try expectRejection(String(repeating: "a", count: DevicePromptPlanner.maximumPromptLength + 1))
        try expectRejection(Array(repeating: "go home", count: DevicePromptPlanner.maximumActions + 1).joined(separator: ";"))
        try expectRejection("swipe up 5 times; swipe down 5 times; press enter 3 times")
        try expect(Array(repeating: "go home", count: DevicePromptPlanner.maximumActions).joined(separator: ";"), Array(repeating: .home, count: DevicePromptPlanner.maximumActions))
        try DevicePromptPlanner.validate(.init(actions: [.openApp("App Store"), .tap(0, 1), .typeText("Hello!\n")]))
        for actions: [PhonePromptAction] in [
            [], [.home, .tap(.nan, 0.5)], [.tap(0.5, .infinity)], [.tap(-0.1, 0)],
            [.typeText("" )], [.typeText("😀")], [.typeText("\u{7F}")],
            [.openApp(" \n ")], [.search("first\nsecond")],
            [.typeText(String(repeating: "a", count: DevicePromptPlanner.maximumTextLength + 1))],
            Array(repeating: .home, count: DevicePromptPlanner.maximumActions + 1),
        ] {
            do {
                try DevicePromptPlanner.validate(.init(actions: actions))
                preconditionFailure("Accepted invalid external plan: \(actions)")
            } catch is PhonePromptPlanningError { }
        }
        print("Device prompt planner tests passed")
    }

    private static func expect(_ prompt: String, _ actions: [PhonePromptAction]) throws {
        let plan = try DevicePromptPlanner.plan(prompt)
        precondition(plan.actions == actions, "Unexpected plan for \(prompt): \(plan.actions)")
    }

    private static func expectRejection(_ prompt: String) throws {
        do {
            _ = try DevicePromptPlanner.plan(prompt)
            preconditionFailure("Accepted unsupported prompt: \(prompt)")
        } catch let error as PhonePromptPlanningError {
            precondition(!(error.errorDescription ?? "").isEmpty)
        }
    }
}
