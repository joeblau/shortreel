import CoreGraphics
import Foundation

// swiftc -swift-version 6 ShortReel/Services/DevicePrompts/{DevicePromptPlan,DevicePromptPlanner,PhoneVisionTypes,PhoneVisionProvider,UITarsActionDecoder,UITarsPhonePlanner,UITarsScreenVerification,LocalUITarsServer}.swift Tests/UITarsPhonePlannerTests.swift -o /tmp/shortreel-uitars-tests
@main
struct UITarsPhonePlannerTests {
    enum Failure: Error { case assertion(String) }

    static func expect(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
        if try !value() { throw Failure.assertion(message) }
    }

    static func rejects(_ operation: () throws -> Void) throws {
        do { try operation() } catch is PhoneVisionError { return } catch is PhonePromptPlanningError { return }
        throw Failure.assertion("Invalid response/configuration was accepted")
    }

    static func decision(_ action: String, thought: String = "The target is visible.") throws -> PhoneVisionDecision {
        try UITarsActionDecoder.decode("Thought: \(thought)\nAction: \(action)")
    }

    static func main() async throws {
        try expect(PhoneVisionProvider.defaultProvider == .codex, "Codex must be the default")
        try expect(PhoneVisionProvider.allCases.first == .codex, "Codex must lead the menu")
        try expect(try decision("click(start_box='(250,750)')") == .action(.tap(0.25, 0.75), reason: "The target is visible."), "Point coordinates were not normalized")
        try expect(try decision("click(start_box='[100,200,300,400]')") == .action(.tap(0.2, 0.3), reason: "The target is visible."), "Box center was not used")
        try expect(try decision("swipe(start_box='(500,250)', end_box='(500,750)')") == .action(.drag(0.5, 0.25, 0.5, 0.75), reason: "The target is visible."), "Spotlight swipe direction changed")
        for key in PhoneKey.allCases {
            try expect(try decision("hotkey(key='\(key.rawValue)')") == .action(.press(key), reason: "The target is visible."), "Catalog key failed: \(key)")
        }
        try expect(UITarsPhonePlanner.instructions.contains(UITarsActionDecoder.actionSpace), "Planner prompt omitted the action catalog")
        // Observation-settled verdicts never consult the model.
        let switcher = PhoneScreenObservation(state: .appSwitcher, appCardsVisible: true, evidence: "SWITCHER")
        let home = PhoneScreenObservation(state: .home, appCardsVisible: false, evidence: "HOME")
        try expect(UITarsPhonePlanner.deterministicReview(.action(.drag(0.3, 0.55, 0.3, 0.1), reason: ""), observation: switcher)?.verdict == .allow, "Upward card swipe in the App Switcher must be allowed without the model")
        try expect(UITarsPhonePlanner.deterministicReview(.action(.drag(0.3, 0.55, 0.8, 0.55), reason: ""), observation: switcher) == nil, "A sideways drag in the App Switcher is left to the model")
        try expect(UITarsPhonePlanner.deterministicReview(.action(.press(.appSwitcher), reason: ""), observation: switcher)?.verdict == .replan, "Reopening the App Switcher must be rejected")
        try expect(UITarsPhonePlanner.deterministicReview(.action(.press(.appSwitcher), reason: ""), observation: home)?.verdict == .allow, "Opening the App Switcher from Home must be allowed")
        try expect(UITarsPhonePlanner.deterministicReview(.action(.home, reason: ""), observation: home)?.verdict == .replan, "Home on Home must be rejected")
        try expect(UITarsPhonePlanner.deterministicReview(.finished("done"), observation: switcher) == nil, "Completion claims always go to the model")
        // An allowed card swipe becomes a flick to the top edge; other inputs are untouched.
        try expect(UITarsPhonePlanner.normalized(.action(.drag(0.3, 0.55, 0.32, 0.3), reason: "r"), for: switcher)
            == .action(.timedDrag(0.3, 0.55, 0.3, 0.02, duration: 0.16, pressDuration: 0, holdDuration: 0), reason: "r"), "Card swipe was not carried to the top edge")
        try expect(UITarsPhonePlanner.normalized(.action(.drag(0.3, 0.55, 0.32, 0.3), reason: "r"), for: home)
            == .action(.drag(0.3, 0.55, 0.32, 0.3), reason: "r"), "Drags outside the App Switcher must not change")
        try expect(UITarsPhonePlanner.normalized(.action(.tap(0.3, 0.55), reason: "r"), for: switcher)
            == .action(.tap(0.3, 0.55), reason: "r"), "Taps must not change")
        for name in ["double_tap", "double_click", "left_double"] {
            try expect(try decision("\(name)(start_box='(250,750)')") == .action(.doubleTap(0.25, 0.75), reason: "The target is visible."), "Double tap lost its coordinates")
        }
        try expect(try decision("long_press(start_box='(250,750)', duration='1.2')") == .action(.longPress(0.25, 0.75, seconds: 1.2), reason: "The target is visible."), "Long press lost timing")
        try expect(try decision("drag(start_box='(100,800)', end_box='(200,300)', duration='0.6', press_duration='0.8', hold_duration='0.2')") == .action(.timedDrag(0.1, 0.8, 0.2, 0.3, duration: 0.6, pressDuration: 0.8, holdDuration: 0.2), reason: "The target is visible."), "Drag lost timing or coordinates")
        for (direction, end): (String, (Double, Double)) in [("down", (0.5, 0.25)), ("up", (0.5, 0.75)), ("left", (0.75, 0.5)), ("right", (0.25, 0.5))] {
            try expect(try decision("scroll(start_box='(500,500)', direction='\(direction)', distance='250')") == .action(.drag(0.5, 0.5, end.0, end.1), reason: "The target is visible."), "Scroll did not move opposite content direction")
        }
        try expect(try decision("open_app_switcher()") == .action(.press(.appSwitcher), reason: "The target is visible."), "App Switcher alias failed")
        try expect(try decision("open_assistive_touch()") == .action(.press(.assistiveTouch), reason: "The target is visible."), "AssistiveTouch alias failed")
        try expect(try decision("wait(seconds='0.5')") == .wait(seconds: 0.5, reason: "The target is visible."), "Wait ignored duration")
        for invalid in [
            "click()", "double_tap()", "long_press(duration='1')",
            "long_press(start_box='(1,2)', duration='NaN')", "long_press(start_box='(1,2)', duration='4')",
            "drag(start_box='(1,2)', end_box='(2,3)', duration='0')",
            "drag(start_box='(1,2)', end_box='(2,3)', press_duration='-1')",
            "drag(start_box='(1,2)', end_box='(2,3)', hold_duration='inf')",
            "scroll(start_box='(500,100)', direction='down', distance='500')",
            "scroll(start_box='(500,500)', direction='north', distance='100')",
            "scroll(start_box='(500,500)', direction='down', distance='0')",
            "wait(seconds='4')", "wait(seconds='NaN')", "wait(extra='1')",
            "open_app_switcher(start_box='(1,2)')"
        ] { try rejects { _ = try decision(invalid) } }
        try expect(try decision("press_home()") == .action(.home, reason: "The target is visible."), "Home must use the existing phone gesture")
        try expect(try decision("hotkey(key='appSwitcher')") == .action(.press(.appSwitcher), reason: "The target is visible."), "App Switcher must be one gesture")
        try rejects { _ = try PhoneVisionDecision.action(.openApp("Safari"), reason: "Compound launch").validated() }
        for (input, output): (String, PhoneKey) in [("enter", .enter), ("selectAll", .selectAll), ("cmd+a", .selectAll), ("addressBar", .addressBar), ("command+l", .addressBar), ("search", .search)] {
            try expect(try decision("hotkey(key='\(input)')") == .action(.press(output), reason: "The target is visible."), "Key mapped incorrectly")
        }
        try expect(try decision(#"type(content='It\'s Safari\\Search')"#) == .action(.typeText("It's Safari\\Search"), reason: "The target is visible."), "Escaped literal text changed")
        try expect(try decision("type(content='Action: finished()')") == .action(.typeText("Action: finished()"), reason: "The target is visible."), "Text was parsed as executable input")
        try expect(try decision("finished()", thought: "Safari shows the requested page.") == .finished("Safari shows the requested page."), "Completion lost evidence")
        try expect(try decision("call_user()") == .needsInput("The target is visible."), "Needs-input result lost")
        try expect(try decision("wait()") == .wait(seconds: 2, reason: "The target is visible."), "Wait escaped runner limits")
        try expect(try UITarsActionDecoder.decode("```\nThought: Visible\nAction: press_home()\n```") == .action(.home, reason: "Visible"), "Fenced response failed")

        // 7B models routinely append prose after the action or use the native
        // finished(content=…) form; both must decode instead of killing a run.
        try expect(try UITarsActionDecoder.decode("Thought: Visible\nAction: press_home()\nThat should show the Home Screen.") == .action(.home, reason: "Visible"), "Trailing prose rejected")
        try expect(try UITarsActionDecoder.decode("Thought: Done\nAction: finished(content='Safari is open')") == .finished("Safari is open"), "finished(content=…) rejected")
        try expect(try UITarsActionDecoder.decode("Thought: Unsure\nAction: call_user(content='Which account?')") == .needsInput("Which account?"), "call_user(content=…) rejected")
        do {
            _ = try UITarsActionDecoder.decode("Thought: ok\nAction: bogus()")
            throw Failure.assertion("Unknown action accepted")
        } catch let error as PhoneVisionError {
            try expect(error.localizedDescription.contains("The model returned"), "Error hid the raw model response")
        }

        for action in [
            "click(start_box='(-1,0)')", "click(start_box='(500,1001)')",
            "click(start_box='(NaN,1)')", "click(start_box='(inf,1)')",
            "click(start_box='[200,100,100,200]')", "click(start_box='(1,2,3)')",
            "click(start_box='(1,2)', start_box='(3,4)')", "click(start_box='(1,2)', extra='x')",
            "press_home(); click(start_box='(1,2)')", "press_home()\nAction: press_home()",
            "type(content=__import__('os'))", "hotkey(key='command+q')",
            "swipe(start_box='(1,2)', end_box='(1,2)')",
            #"type(content='Safari\n')"#, #"type(content='\x41')"#,
            "type(content='\(String(repeating: "a", count: 101))')", "type(content='')",
            "type(content='🙂')", "finished(extra='ignored')", "click(start_box='(1,2)',)", "close_all_apps()"
        ] { try rejects { _ = try decision(action) } }
        try rejects { _ = try UITarsActionDecoder.decode("Action: press_home()") }
        try rejects { _ = try UITarsActionDecoder.decode(String(repeating: "x", count: 40_000)) }

        let config = UITarsPhonePlanner.Configuration(baseURL: "https://model.invalid/v1/", apiKey: "test-secret", model: "ui-tars")
        try expect(try config.endpoint().absoluteString == "https://model.invalid/v1/chat/completions", "Wrong chat endpoint")
        let pixelConfig = UITarsPhonePlanner.Configuration(baseURL: "http://127.0.0.1:11435/v1", apiKey: "local", model: "ui-tars-1.5-7b")
        let pixelSpace = try pixelConfig.coordinateDimensions(width: 591, height: 1280)
        try expect(pixelSpace.width == 588 && pixelSpace.height == 1288, "UI-TARS 1.5 smart resize changed")
        let replay = try UITarsActionDecoder.decode("Thought: Safari is visible.\nAction: click(start_box='(80,792)')",
            coordinateWidth: 504, coordinateHeight: 1120)
        try expect(replay == .action(.tap(80.0 / 504, 792.0 / 1120), reason: "Safari is visible."), "Pixel coordinates were incorrectly divided by 1000")
        let bottom = try UITarsActionDecoder.decode("Thought: Tap the bottom control.\nAction: click(start_box='(294,1200)')",
            coordinateWidth: pixelSpace.width, coordinateHeight: pixelSpace.height)
        try expect(bottom == .action(.tap(0.5, 1200.0 / 1288), reason: "Tap the bottom control."), "Valid pixel Y above 1000 was rejected")
        try rejects {
            _ = try UITarsActionDecoder.decode("Thought: Off screen.\nAction: click(start_box='(600,1200)')", coordinateWidth: 588, coordinateHeight: 1288)
        }
        let explicit = UITarsPhonePlanner.Configuration(baseURL: "http://localhost/v1", apiKey: "local", model: "ui-tars-1.5", coordinateSpace: .normalized1000)
        try expect(try explicit.coordinateDimensions(width: 591, height: 1280).height == 1000, "Explicit coordinate mode was ignored")
        let override = try JSONDecoder().decode(UITarsPhonePlanner.Configuration.self,
            from: Data(#"{"baseURL":"http://localhost/v1","apiKey":"local","model":"custom","coordinateSpace":"uiTars15"}"#.utf8))
        try expect(try override.coordinateDimensions(width: 513, height: 1114).width == 504, "Saved pixel-coordinate mode was ignored")
        try rejects { _ = try decision("press_home(); click(start_box='(1,2)')") }
        try rejects { _ = try decision("press_home()\nclick(start_box='(1,2)')") }
        let responsesConfig = UITarsPhonePlanner.Configuration(baseURL: "http://127.0.0.1:8000/v1", apiKey: "test", model: "ui-tars", useResponsesApi: true)
        try expect(try responsesConfig.endpoint().path == "/v1/responses", "Responses configuration ignored")
        for endpoint in ["file:///tmp/config", "https://user:password@host/v1", "https://host/v1?key=secret", "not a url"] {
            try rejects { _ = try UITarsPhonePlanner.Configuration(baseURL: endpoint, apiKey: "test", model: "model").endpoint() }
        }
        try rejects { _ = try UITarsPhonePlanner.Configuration(baseURL: "https://host", apiKey: "test\r\nX: value", model: "model").endpoint() }
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }
        let configFile = temp.appendingPathComponent("config.json")
        try rejects { _ = try UITarsPhonePlanner.loadConfiguration(from: configFile) }
        try Data(#"{"baseURL":"https://host/v1","apiKey":"private","model":"ui-tars"}"#.utf8).write(to: configFile)
        try expect(try UITarsPhonePlanner.loadConfiguration(from: configFile).useResponsesApi == false, "Older CLI configuration must work")
        try Data("not JSON private".utf8).write(to: configFile)
        do { _ = try UITarsPhonePlanner.loadConfiguration(from: configFile) }
        catch { try expect(!error.localizedDescription.contains("private"), "Configuration leaked into error") }

        let image = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!.makeImage()!
        let frame = PhoneScreenFrame(id: UUID(), capturedAt: Date(), pixelWidth: 1, pixelHeight: 1,
            jpegData: Data([1, 2, 3]), cgImage: image, sourceID: "selected-phone")
        let history = [PhoneVisionStep(id: UUID(), number: 1, action: "Go Home", detail: "Return Home", capturedAt: Date())]
        let request = try UITarsPhonePlanner.makeRequest(goal: "Open Safari", frame: frame, history: history, configuration: config)
        try expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-secret", "CLI key was not reused")
        let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
        try expect(body["model"] as? String == "ui-tars", "Configured model ignored")
        let messages = body["messages"] as! [[String: Any]]
        let content = messages[0]["content"] as! [[String: Any]]
        try expect((content[0]["text"] as! String).contains("Go Home"), "Action history missing")
        try expect((content[2]["image_url"] as! [String: String])["url"] == "data:image/jpeg;base64,AQID", "Wrong phone image")
        let responsesRequest = try UITarsPhonePlanner.makeRequest(goal: "Open Safari", frame: frame, history: [], configuration: responsesConfig)
        let responsesBody = try JSONSerialization.jsonObject(with: responsesRequest.httpBody!) as! [String: Any]
        try expect(responsesBody["input"] != nil && responsesBody["messages"] == nil && responsesBody["store"] as? Bool == false, "Responses request shape incorrect")

        let text = "Thought: Home is visible. Open Spotlight.\nAction: swipe(start_box='(500,250)', end_box='(500,750)')"
        let chat = try JSONSerialization.data(withJSONObject: ["choices": [["finish_reason": "stop", "message": ["role": "assistant", "content": text]]]])
        let response = try JSONSerialization.data(withJSONObject: ["status": "completed", "output": [["type": "message", "role": "assistant", "content": [["type": "output_text", "text": text]]]]])
        try expect(try UITarsPhonePlanner.decodeResponse(chat, useResponsesApi: false) == UITarsPhonePlanner.decodeResponse(response, useResponsesApi: true), "API formats map differently")
        for data in [
            Data("not JSON".utf8),
            try JSONSerialization.data(withJSONObject: ["choices": [["finish_reason": "length", "message": ["content": text]]]]),
            try JSONSerialization.data(withJSONObject: ["choices": [["finish_reason": "stop", "message": ["content": text, "tool_calls": [["type": "function"]]]]]]),
            Data(repeating: 32, count: 1_048_577)
        ] { try rejects { _ = try UITarsPhonePlanner.decodeResponse(data, useResponsesApi: false) } }
        try rejects { _ = try UITarsPhonePlanner.decodeResponse(Data(#"{"status":"incomplete","output":[]}"#.utf8), useResponsesApi: true) }

        let sessionConfig = URLSessionConfiguration.ephemeral
        sessionConfig.protocolClasses = [StubProtocol.self]
        let session = URLSession(configuration: sessionConfig)
        defer { session.invalidateAndCancel() }
        StubProtocol.set(status: 200, body: chat)
        let result = try await UITarsPhonePlanner.nextDecision(goal: "Open Safari", frame: frame, history: history, configuration: config, session: session)
        try expect(result == UITarsPhonePlanner.decodeResponse(chat, useResponsesApi: false), "HTTP result not decoded")
        let pixelFrame = PhoneScreenFrame(id: UUID(), capturedAt: Date(), pixelWidth: 589, pixelHeight: 1280,
            jpegData: frame.jpegData, cgImage: image, sourceID: "selected-phone")
        let pixelTransport = UITarsPhonePlanner.Configuration(baseURL: config.baseURL, apiKey: "local", model: "ui-tars-1.5-7b")
        let pixelRequest = try UITarsPhonePlanner.makeRequest(goal: "Open Safari", frame: pixelFrame, history: [], configuration: pixelTransport)
        let pixelBody = try JSONSerialization.jsonObject(with: pixelRequest.httpBody!) as! [String: Any]
        let pixelMessages = pixelBody["messages"] as! [[String: Any]]
        let pixelContent = pixelMessages[0]["content"] as! [[String: Any]]
        try expect((pixelContent[0]["text"] as! String).contains("(588,1288)"), "Request did not declare the pixel bounds")
        let pixelReply = try JSONSerialization.data(withJSONObject: ["choices": [["finish_reason": "stop", "message": ["role": "assistant", "content": "Thought: Bottom control visible.\nAction: click(start_box='(294,1200)')"]]]])
        StubProtocol.set(status: 200, body: pixelReply)
        let pixelResult = try await UITarsPhonePlanner.nextDecision(goal: "Tap the bottom control", frame: pixelFrame, history: [], configuration: pixelTransport, session: session)
        try expect(pixelResult == .action(.tap(0.5, 1200.0 / 1288), reason: "Bottom control visible."), "HTTP response lost the frame coordinate dimensions")
        for status in [302, 401, 429, 500] {
            StubProtocol.set(status: status, body: Data("server-secret".utf8))
            do {
                _ = try await UITarsPhonePlanner.nextDecision(goal: "Open Safari", frame: frame, history: [], configuration: config, session: session)
                throw Failure.assertion("HTTP failure dispatched input")
            } catch let error as PhoneVisionError {
                try expect(!error.localizedDescription.contains("server-secret"), "Server body leaked")
            }
        }
        StubProtocol.set(status: 200, body: chat, stall: true)
        let task = Task {
            try await UITarsPhonePlanner.nextDecision(goal: "Open Safari", frame: frame, history: [], configuration: config, session: session)
        }
        while !StubProtocol.hasStarted { try await Task.sleep(for: .milliseconds(5)) }
        task.cancel()
        do { _ = try await task.value; throw Failure.assertion("Cancelled model request completed") }
        catch is CancellationError { }
        print("UI-TARS tests passed: action decoding, validation, CLI config, both APIs, transport errors, and cancellation")
    }
}

private final class StubProtocol: URLProtocol, @unchecked Sendable {
    private final class State: @unchecked Sendable {
        let lock = NSLock()
        var status = 200
        var body = Data()
        var stall = false
        var started = false
    }
    private static let state = State()
    static func set(status: Int, body: Data, stall: Bool = false) {
        state.lock.withLock {
            state.status = status; state.body = body; state.stall = stall; state.started = false
        }
    }
    static var hasStarted: Bool { state.lock.withLock { state.started } }
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "model.invalid" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let (status, originalBody, stall) = Self.state.lock.withLock {
            Self.state.started = true
            return (Self.state.status, Self.state.body, Self.state.stall)
        }
        if stall { return }
        var body = originalBody
        if status == 200, let data = request.httpBody ?? readBody(),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let messages = (object["messages"] ?? object["input"]) as? [[String: Any]],
           let content = messages.first?["content"] as? [[String: Any]],
           let prompt = content.first?["text"] as? String {
            var answer: String?
            if prompt == UITarsPhonePlanner.perceptionPrompt {
                answer = #"{"state":"home","appCardsVisible":false,"evidence":"An app grid and dock are visible."}"#
            } else if prompt.hasPrefix("Check whether ONE proposed next input") {
                answer = #"{"verdict":"allow","evidence":"The proposed input matches the visible screen."}"#
            }
            if let answer {
                body = try! JSONSerialization.data(withJSONObject: ["choices": [["finish_reason": "stop", "message": ["role": "assistant", "content": answer]]]])
            }
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
    private func readBody() -> Data? {
        guard let stream = request.httpBodyStream else { return nil }
        stream.open(); defer { stream.close() }
        var data = Data(), bytes = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&bytes, maxLength: bytes.count)
            guard count > 0 else { break }
            data.append(contentsOf: bytes.prefix(count))
        }
        return data
    }
    override func stopLoading() { }
}
