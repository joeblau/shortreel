import CoreGraphics
import Foundation
import AppKit

@main
struct UITarsScreenVerificationTests {
    enum Failure: Error { case assertion(String) }
    static func check(_ value: Bool, _ message: String) throws {
        if !value { throw Failure.assertion(message) }
    }

    @MainActor static func searchFrame(suggestions: Bool = true, keyboard: Bool = true, app: String? = nil) -> PhoneScreenFrame {
        let context = CGContext(data: nil, width: 480, height: 1040, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(NSColor.black.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: 480, height: 1040))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        func label(_ text: String, _ x: CGFloat, _ y: CGFloat) {
            (text as NSString).draw(at: CGPoint(x: x, y: y), withAttributes: [
                .font: NSFont.systemFont(ofSize: 20), .foregroundColor: NSColor.white
            ])
        }
        if let app {
            label("Top Hit", 20, 930)
            label(app, 65, 810)
            label("Suggestions", 20, 750)
            label(app, 65, 690)
        } else if suggestions {
            label("Siri Suggestions", 20, 930)
            label("Show More", 350, 930)
        }
        label("Q Search", 25, 410)
        if keyboard {
            for (index, key) in ["w", "e", "u", "a", "s", "d", "z", "c", "n"].enumerated() {
                label(key, CGFloat(index % 3) * 90 + 60, 310 - CGFloat(index / 3) * 70)
            }
        }
        NSGraphicsContext.restoreGraphicsState()
        let image = context.makeImage()!
        return .init(id: UUID(), capturedAt: Date(), pixelWidth: 480, pixelHeight: 1040,
            jpegData: NSBitmapImageRep(cgImage: image).representation(using: .jpeg, properties: [:])!,
            cgImage: image, sourceID: "SR1")
    }
    static func main() async throws {
        let image = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!.makeImage()!
        func frame(_ seconds: Double, source: String = "SR1") -> PhoneScreenFrame {
            .init(id: UUID(), capturedAt: Date(timeIntervalSince1970: seconds), pixelWidth: 1, pixelHeight: 1,
                  jpegData: Data([1, 2, 3]), cgImage: image, sourceID: source)
        }
        let before = frame(1), after = frame(2), current = frame(3)
        let wrong = frame(1, source: "SR2")
        let history = [PhoneVisionStep(id: UUID(), number: 1, action: "Tap", detail: "FALSE CLAIM: switcher is open",
            capturedAt: before.capturedAt, input: .tap(0.12345, 0.76543), beforeFrame: before, afterFrame: after, screenChanged: false)]
        for responses in [false, true] {
            let config = UITarsPhonePlanner.Configuration(baseURL: "https://verify.invalid/v1", apiKey: "test", model: "ui-tars", useResponsesApi: responses)
            let request = try UITarsPhonePlanner.makeRequest(goal: "Close apps", frame: current, history: history, configuration: config)
            let object = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
            let messages = object[responses ? "input" : "messages"] as! [[String: Any]]
            let content = messages[0]["content"] as! [[String: Any]]
            let prompt = content[0]["text"] as! String
            try check(!prompt.contains("FALSE CLAIM"), "Model speculation contaminated execution history")
            try check(prompt.contains("0.12345") && prompt.contains("did not materially change"), "Exact action/outcome missing")
            try check(content.filter { $0["type"] as? String == (responses ? "input_image" : "image_url") }.count == 3, "Before/after/current images missing")
            try check((content[content.count - 2]["text"] as? String)?.hasPrefix("CURRENT SCREEN") == true, "Current frame must be last")
            var foreignHistory = history
            foreignHistory[0].beforeFrame = wrong
            foreignHistory[0].afterFrame = frame(4)
            let filtered = try UITarsPhonePlanner.makeRequest(goal: "Close apps", frame: current, history: foreignHistory, configuration: config)
            let filteredText = String(data: filtered.httpBody!, encoding: .utf8)!
            try check(!filteredText.contains("BEFORE input") && !filteredText.contains("AFTER input"), "Foreign/future frames leaked")
        }
        for (text, state): (String, PhoneScreenObservation.State) in [
            ("SPOTLIGHT: Siri Suggestions, Search field and keyboard", .spotlight),
            ("Editing. Minus badges are visible.", .homeEditing),
            ("SWITCHER; overlapping app preview cards.", .appSwitcher),
            ("APP (one full-screen app)", .foregroundApp), ("HOME\nApp icons.", .home)
        ] {
            try check(try PhoneScreenObservation.decode(text).state == state, "Label observation lost state")
        }
        let config = UITarsPhonePlanner.Configuration(baseURL: "https://verify.invalid/v1", apiKey: "test", model: "ui-tars")
        let sessionConfig = URLSessionConfiguration.ephemeral
        sessionConfig.protocolClasses = [ReviewProtocol.self]
        let session = URLSession(configuration: sessionConfig)
        defer { session.invalidateAndCancel() }
        let observation = #"{"state":"homeEditing","appCardsVisible":false,"evidence":"Icon minus badges and Done are visible."}"#
        let badTap = "Thought: Tap minus to close the app.\nAction: click(start_box='(100,200)')"
        let reject = #"{"verdict":"replan","evidence":"Home editing minus buttons remove apps. Exit editing, then open App Switcher."}"#
        let home = "Thought: Tap Done to exit Home editing.\nAction: click(start_box='(900,100)')"
        let allow = #"{"verdict":"allow","evidence":"Done exits editing without removing anything."}"#
        ReviewProtocol.set([observation, badTap, reject, home, allow])
        let repaired = try await UITarsPhonePlanner.nextDecision(goal: "Close all apps", frame: current, history: [], configuration: config, session: session)
        try check(repaired == .action(.tap(0.9, 0.1), reason: "Tap Done to exit Home editing."), "Rejected tap escaped before repair")
        try check(ReviewProtocol.count == 5, "Repair must be bounded to one additional proposal/review")
        ReviewProtocol.set([observation, badTap, reject, badTap, reject])
        let stopped = try await UITarsPhonePlanner.nextDecision(goal: "Close all apps", frame: current, history: [], configuration: config, session: session)
        guard case .needsInput = stopped else { throw Failure.assertion("Repeatedly rejected proposal escaped") }
        try check(ReviewProtocol.count == 5, "Repeated rejection looped")
        for replies in [["not an observation"], [observation, badTap, "not a review"]] {
            ReviewProtocol.set(replies)
            do {
                _ = try await UITarsPhonePlanner.nextDecision(goal: "Close apps", frame: current, history: [], configuration: config, session: session)
                throw Failure.assertion("Invalid observation/review failed open")
            } catch is PhoneVisionError { }
            try check(ReviewProtocol.count == replies.count, "Invalid verification proceeded to another request")
        }
        do {
            _ = try PhoneScreenObservation.decode(#"{"state":"appSwitcher","appCardsVisible":false,"evidence":"Full-screen Safari."}"#)
            throw Failure.assertion("Contradictory switcher evidence accepted")
        } catch is PhoneVisionError { }
        ReviewProtocol.set([#"{"verdict":"replan","evidence":"The user requested opening News, not closing it."}"#])
        let rejectedSwipe = try await UITarsPhonePlanner.reviewDecision(.action(.drag(0.5, 0.6, 0.5, 0.1), reason: "Swipe"),
            goal: "Open News", frame: current, history: [], observation: .init(state: .appSwitcher, appCardsVisible: true, evidence: "Cards"),
            configuration: config, session: session)
        try check(rejectedSwipe.verdict == .replan && ReviewProtocol.count == 1, "Mechanical validity bypassed goal verification")
        ReviewProtocol.set(["SWITCHER: app preview cards", "Thought: Close the visible News card.\nAction: drag(start_box='(500,600)', end_box='(500,300)')", allow])
        let flick = try await UITarsPhonePlanner.nextDecision(goal: "Close News", frame: current, history: [], configuration: config, session: session)
        try check(flick == .action(.timedDrag(0.5, 0.6, 0.5, 0.02, duration: 0.16, pressDuration: 0, holdDuration: 0), reason: "Close the visible News card."), "Card dismissal did not use the quick flick")
        try check(ReviewProtocol.lastRequest.contains("duration: 0.16") && ReviewProtocol.lastRequest.contains("y=0.02"), "Critic did not review the gesture actually sent")
        let spotlightSwipe = "Thought: Home is visible. Swipe down to open Spotlight.\nAction: swipe(start_box='(500,350)', end_box='(500,700)')"
        ReviewProtocol.set(["HOME: app icons and Search", spotlightSwipe,
            #"{"verdict":"allow","evidence":"Swipe down from Home to open Spotlight before searching for TikTok."}"#])
        let launch = try await UITarsPhonePlanner.nextDecision(goal: "open tiktok", frame: current, history: [], configuration: config, session: session)
        try check(launch == .action(.drag(0.5, 0.35, 0.5, 0.7), reason: "Home is visible. Swipe down to open Spotlight."), "Home launch changed into a dismissal or stopped")
        try check(ReviewProtocol.count == 2, "Verified Home search prerequisite depended on speculative app-target review")
        try check(ReviewProtocol.lastRequest.contains("open tiktok") && ReviewProtocol.lastRequest.contains("Prefer a single coordinate tap"), "Home planner lost the app name or tap preference")
        let iconTap = "Thought: Tap TikTok’s visible Dock icon.\nAction: click(start_box='(610,920)')"
        ReviewProtocol.set(["HOME: TikTok icon in the Dock", iconTap,
            #"{"verdict":"allow","evidence":"The coordinates land on TikTok’s Dock icon in the current screenshot."}"#])
        let directLaunch = try await UITarsPhonePlanner.nextDecision(goal: "Open TikTok", frame: current, history: [], configuration: config, session: session)
        try check(directLaunch == .action(.tap(0.61, 0.92), reason: "Tap TikTok’s visible Dock icon."), "Visible Dock icon could not be tapped directly")
        try check(ReviewProtocol.count == 3, "Home icon tap bypassed visual target review")
        ReviewProtocol.set([#"{"verdict":"replan","evidence":"Those coordinates point at Instagram, not TikTok."}"#])
        let wrongIcon = try await UITarsPhonePlanner.reviewDecision(.action(.tap(0.83, 0.92), reason: "Open TikTok"), goal: "Open TikTok", frame: current,
            history: [], observation: .init(state: .home, appCardsVisible: false, evidence: "Home icons"), configuration: config, session: session)
        try check(wrongIcon.verdict == .replan && ReviewProtocol.count == 1, "Wrong app icon bypassed visual target review")
        ReviewProtocol.set([#"{"verdict":"replan","evidence":"TikTok is not foreground; its Home icon does not prove it opened."}"#])
        let premature = try await UITarsPhonePlanner.reviewDecision(.finished("TikTok is open"), goal: "open tiktok", frame: current,
            history: [], observation: .init(state: .home, appCardsVisible: false, evidence: "Home icons"), configuration: config, session: session)
        try check(premature.verdict == .replan && ReviewProtocol.count == 0, "Home launch completion bypassed the navigation prerequisite")
        for action: PhonePromptAction in [.typeText("TikTok"), .press(.appSwitcher), .drag(0.5, 0.95, 0.5, 0.3)] {
            ReviewProtocol.set([])
            let blocked = try await UITarsPhonePlanner.reviewDecision(.action(action, reason: "Open TikTok"), goal: "open tiktok", frame: current,
                history: [], observation: .init(state: .home, appCardsVisible: false, evidence: "Home"), configuration: config, session: session)
            try check(blocked.verdict == .replan && ReviewProtocol.count == 0, "Home launch allowed typing or an unrelated gesture")
        }
        let homeObservation = PhoneScreenObservation(state: .home, appCardsVisible: false, evidence: "Home")
        try check(UITarsPhonePlanner.planningGoal("Open Maps", observation: homeObservation).contains("Open Maps"), "Home launch guidance lost the requested app")
        try check(UITarsPhonePlanner.planningGoal("Close all apps", observation: homeObservation) == "Close all apps", "Closing goal was rewritten as a launch")
        let spotlightGoal = UITarsPhonePlanner.planningGoal("Open TikTok", observation: .init(state: .spotlight, appCardsVisible: false, evidence: "Search"))
        try check(spotlightGoal.contains("Open TikTok") && spotlightGoal.contains("ALREADY OPEN"), "Spotlight search lost the requested app or current navigation state")
        let search = searchFrame()
        try check(try UITarsPhonePlanner.spotlightObservation(in: search.cgImage)?.state == .spotlight, "Visible Spotlight controls were mistaken for Home")
        try check(try UITarsPhonePlanner.spotlightObservation(in: searchFrame(suggestions: false).cgImage) == nil, "An ordinary app search was classified as Spotlight")
        try check(try UITarsPhonePlanner.spotlightObservation(in: searchFrame(keyboard: false).cgImage) == nil, "Suggestions without a keyboard authorized typing")
        ReviewProtocol.set(["Thought: Spotlight is open. Type the requested app name.\nAction: type(content='TikTok')",
            #"{"verdict":"allow","evidence":"The empty Spotlight field is focused with the keyboard visible."}"#])
        let typeApp = try await UITarsPhonePlanner.nextDecision(goal: "Open TikTok", frame: search, history: history, configuration: config, session: session)
        try check(typeApp == .action(.typeText("TikTok"), reason: "Spotlight is open. Type the requested app name."), "Open Spotlight repeated its opening swipe instead of typing")
        try check(ReviewProtocol.count == 1, "Text-verified empty Spotlight search depended on speculative app-target review")
        ReviewProtocol.set([])
        let wrongQuery = try await UITarsPhonePlanner.reviewDecision(.action(.typeText("Safari"), reason: "Search"), goal: "Open TikTok", frame: search,
            history: [], observation: .init(state: .spotlight, appCardsVisible: false, evidence: "Empty Search"), configuration: config, session: session)
        try check(wrongQuery.verdict == .replan && ReviewProtocol.count == 0, "Spotlight search accepted another app's name")
        let results = searchFrame(app: "TikTok")
        let appRegion = try UITarsPhonePlanner.spotlightAppRegion(in: results.cgImage, app: "TikTok")
        try check(appRegion?.contains(CGPoint(x: 0.2, y: 0.16)) == true, "Top Hit app region was not grounded in its heading and caption")
        try check(try UITarsPhonePlanner.spotlightAppRegion(in: results.cgImage, app: "Maps") == nil, "Another app's label was used as the requested target")
        ReviewProtocol.set([])
        let webTap = try await UITarsPhonePlanner.reviewDecision(.action(.tap(0.2, 0.34), reason: "Open app"), goal: "Open TikTok", frame: results,
            history: [], observation: .init(state: .spotlight, appCardsVisible: false, evidence: "Top Hit and web suggestions"), configuration: config, session: session)
        try check(webTap.verdict == .replan && ReviewProtocol.count == 0, "Web suggestion escaped the installed-app target check")
        ReviewProtocol.set([allow])
        let appTap = try await UITarsPhonePlanner.reviewDecision(.action(.tap(0.2, 0.16), reason: "Open app"), goal: "Open TikTok", frame: results,
            history: [], observation: .init(state: .spotlight, appCardsVisible: false, evidence: "Top Hit"), configuration: config, session: session)
        try check(appTap.verdict == .allow && ReviewProtocol.count == 0, "Text-verified installed-app target was rejected")
        let browser = "UNKNOWN: Google search results for tiktok, with Safari's address field and no Home icons or preview cards."
        let otherApp = #"{"state":"otherScreen","evidence":"Safari shows Google results for TikTok, not the installed TikTok app."}"#
        ReviewProtocol.set([browser, otherApp])
        let recoverUnknown = try await UITarsPhonePlanner.nextDecision(goal: "open the tiktok app", frame: current,
            history: history, configuration: config, session: session)
        guard case .action(.press(.assistiveTouch), _) = recoverUnknown else {
            throw Failure.assertion("Unclassified browser recovery used a Home swipe")
        }
        try check(ReviewProtocol.count == 2, "Unknown recovery guessed visual coordinates")
        ReviewProtocol.set(["APP: Safari displays Google results for TikTok.", otherApp,
            "Thought: Tap the floating AssistiveTouch button.\nAction: click(start_box='(890,50)')", allow])
        let leaveBrowser = try await UITarsPhonePlanner.nextDecision(goal: "open the tiktok app", frame: current,
            history: history, configuration: config, session: session)
        try check(leaveBrowser == .action(.tap(0.89, 0.05), reason: "Tap the floating AssistiveTouch button."), "Browser launch bypassed AssistiveTouch")
        try check(ReviewProtocol.count == 4, "AssistiveTouch tap bypassed visual target review")
        ReviewProtocol.set(["ASSISTIVETOUCH: menu with Home control",
            "Thought: Tap Home in AssistiveTouch.\nAction: click(start_box='(500,700)')", allow])
        let menuHome = try await UITarsPhonePlanner.nextDecision(goal: "Go Home", frame: current,
            history: [], configuration: config, session: session)
        try check(menuHome == .action(.tap(0.5, 0.7), reason: "Tap Home in AssistiveTouch."), "Observed menu did not use its Home control")
        ReviewProtocol.set([])
        let homeSwipe = try await UITarsPhonePlanner.reviewDecision(.action(.home, reason: "Go Home"), goal: "Go Home", frame: current,
            history: [], observation: .init(state: .foregroundApp, appCardsVisible: false, evidence: "Safari"), configuration: config, session: session)
        try check(homeSwipe.verdict == .replan && ReviewProtocol.count == 0, "Legacy Home gesture escaped review")
        ReviewProtocol.set(["HOME: app grid and Search", spotlightSwipe])
        let openSearch = try await UITarsPhonePlanner.nextDecision(goal: "open the tiktok app", frame: current,
            history: [], configuration: config, session: session)
        guard case .action(.drag, _) = openSearch else { throw Failure.assertion("Recovery did not continue through Spotlight") }
        ReviewProtocol.set(["Thought: Spotlight is open. Type the app name.\nAction: type(content='tiktok')", allow])
        let searchApp = try await UITarsPhonePlanner.nextDecision(goal: "open the tiktok app", frame: search,
            history: [], configuration: config, session: session)
        guard case .action(.typeText("tiktok"), _) = searchApp else { throw Failure.assertion("Recovery typed the wrong app name") }
        ReviewProtocol.set(["SPOTLIGHT: TikTok installed-app result", "Thought: Tap the matching installed app.\nAction: click(start_box='(200,160)')", allow])
        let selectApp = try await UITarsPhonePlanner.nextDecision(goal: "open the tiktok app", frame: results,
            history: [], configuration: config, session: session)
        guard case .action(.tap(0.2, 0.16), _) = selectApp else { throw Failure.assertion("Recovery did not select the installed app") }
        for app in ["TikTok", "Maps", "Safari"] {
            for layout in ["APP: The requested app's own interface.", "UNKNOWN: Full-screen interface."] {
                ReviewProtocol.set([layout, #"{"state":"targetApp","evidence":"The requested app's own interface is visibly foreground."}"#])
                let alreadyOpen = try await UITarsPhonePlanner.nextDecision(goal: "Open \(app)", frame: current,
                    history: [], configuration: config, session: session)
                guard case .finished = alreadyOpen else { throw Failure.assertion("A foreground app was relaunched") }
                try check(ReviewProtocol.count == 2, "Foreground verification required unnecessary inputs")
            }
        }
        ReviewProtocol.set([browser, #"{"state":"unavailable","evidence":"The phone is locked."}"#])
        let locked = try await UITarsPhonePlanner.nextDecision(goal: "Open TikTok", frame: current,
            history: [], configuration: config, session: session)
        guard case .needsInput = locked else { throw Failure.assertion("An unavailable phone authorized navigation") }
        for invalid in ["not JSON", #"{"state":"otherScreen","evidence":""}"#, #"{"state":"maybe","evidence":"A screen"}"#] {
            ReviewProtocol.set([browser, invalid])
            do {
                _ = try await UITarsPhonePlanner.nextDecision(goal: "Open TikTok", frame: current,
                    history: [], configuration: config, session: session)
                throw Failure.assertion("Invalid app identity verification authorized navigation")
            } catch is PhoneVisionError { }
            try check(ReviewProtocol.count == 2, "Invalid app verification proceeded to planning")
        }
        ReviewProtocol.set(["APP: TikTok is foreground", "Thought: Enter the requested text.\nAction: type(content='hello')", allow])
        let compound = try await UITarsPhonePlanner.nextDecision(goal: "Open TikTok then type hello", frame: current,
            history: [], configuration: config, session: session)
        guard case .action(.typeText("hello"), _) = compound else { throw Failure.assertion("Opening an app prematurely completed a compound goal") }
        ReviewProtocol.set(["UNKNOWN: screen is obscured"])
        let unknown = try await UITarsPhonePlanner.nextDecision(goal: "Close apps", frame: current, history: [], configuration: config, session: session)
        guard case .needsInput = unknown else { throw Failure.assertion("Unknown screen reached action planning") }
        try check(ReviewProtocol.count == 1, "Unknown screen sent additional requests")
        print("UI-TARS verification tests passed: app switching and foreground identity, history, image isolation, rejected deletion, bounded repair, fail-closed parsing")
    }
}

private final class ReviewProtocol: URLProtocol, @unchecked Sendable {
    private final class State: @unchecked Sendable {
        let lock = NSLock()
        var replies: [String] = []
        var count = 0
        var lastRequest = ""
    }
    private static let state = State()
    static var count: Int { state.lock.withLock { state.count } }
    static var lastRequest: String { state.lock.withLock { state.lastRequest } }
    static func set(_ replies: [String]) { state.lock.withLock { state.replies = replies; state.count = 0 } }
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "verify.invalid" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var requestData = request.httpBody ?? Data()
        if requestData.isEmpty, let stream = request.httpBodyStream {
            stream.open()
            var bytes = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&bytes, maxLength: bytes.count)
                guard count > 0 else { break }
                requestData.append(contentsOf: bytes.prefix(count))
            }
            stream.close()
        }
        Self.state.lock.withLock { Self.state.lastRequest = String(decoding: requestData, as: UTF8.self) }
        let reply = Self.state.lock.withLock {
            Self.state.count += 1
            return Self.state.replies.isEmpty ? "UNEXPECTED EXTRA REQUEST" : Self.state.replies.removeFirst()
        }
        let body = try! JSONSerialization.data(withJSONObject: ["choices": [["finish_reason": "stop", "message": ["role": "assistant", "content": reply]]]])
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
