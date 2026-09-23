import AppKit
import Darwin
import Foundation

@main
struct CodexPhonePlannerTests {
    enum Failure: Error { case assertion(String) }
    static func check(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
        if try !value() { throw Failure.assertion(message) }
    }

    static func response(_ decision: [String: Any]? = nil, state: String = "foregroundApp") throws -> Data {
        var value: [String: Any] = ["screen": ["state": state, "appCardsVisible": state == "appSwitcher", "evidence": "Visible \(state) interface."]]
        if let decision { value["decision"] = decision }
        return try JSONSerialization.data(withJSONObject: value)
    }

    @MainActor static func browserFrame(source: String = "SR1", date: Date = Date()) -> PhoneScreenFrame {
        let context = CGContext(data: nil, width: 480, height: 1040, bitsPerComponent: 8, bytesPerRow: 480 * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 480, height: 1040))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        for (text, y) in [("9:41", 1000), ("Google", 880), ("Search: tiktok", 800), ("All     Images     Videos", 745),
                          ("TikTok", 660), ("https://www.tiktok.com", 620), ("Watch trending videos on the web", 575),
                          ("Safari", 100), ("google.com/search?q=tiktok", 60), ("<       >       Share       Tabs", 20)] {
            (text as NSString).draw(at: NSPoint(x: 20, y: y), withAttributes: [.font: NSFont.systemFont(ofSize: 22), .foregroundColor: NSColor.black])
        }
        NSGraphicsContext.restoreGraphicsState()
        let image = context.makeImage()!
        return .init(id: UUID(), capturedAt: date, pixelWidth: 480, pixelHeight: 1040,
            jpegData: NSBitmapImageRep(cgImage: image).representation(using: .jpeg, properties: [:])!, cgImage: image, sourceID: source)
    }

    @MainActor static func main() async throws {
        if CommandLine.arguments.dropFirst().first == "exec" { try fakeCLI(); return }
        let notes = (1...40).map { number in
            PhoneVisionStep(id: UUID(), number: number, action: "Tap", detail: "Verified page \(number)", capturedAt: Date(),
                progressNote: "Verified page \(number)")
        }
        let progress = PhonePlannerContext.progressNotes(notes)
        try check(progress.contains("1. Verified page 1") && progress.contains("40. Verified page 40"),
            "Long-task progress was lost beyond the eight recent inputs")
        let routedNotes = notes.map { step in
            var step = step
            step.pageState = "videoPlayer"
            step.decisionSource = "state tree"
            return step
        }
        let routedProgress = PhonePlannerContext.progressNotes(routedNotes)
        try check(routedProgress.components(separatedBy: "\n").count == 8
            && routedProgress.hasPrefix("33.") && !routedProgress.contains("1. Verified page 1"),
            "State-tree runs kept an unbounded reasoning history")
        try check(routedNotes[0].executionFeedback.contains("Page: videoPlayer; decision: state tree"),
            "Route evidence was omitted from planner feedback")
        try decoderTests()
        var video: [String: Any] = ["creator": "@creator", "caption": "A stable video caption",
            "progress": 0.5, "durationSeconds": 20, "playing": true]
        func observedVideo() throws -> PhoneScreenObservation {
            try PhonePlannerResponse.observation(from: JSONSerialization.data(withJSONObject: ["screen": [
                "state": "foregroundApp", "appCardsVisible": false, "evidence": "The video player is visible.",
                "checkEvidence": "A playing video.", "video": video]]))
        }
        let observation = try observedVideo()
        try check(observation.checkEvidence == "A playing video." && observation.video?.progress == 0.5,
            "Focused UI evidence or playback measurements were discarded")
        video["progress"] = 1.5
        do {
            _ = try observedVideo()
            throw Failure.assertion("An invalid playhead fraction was accepted")
        } catch is PhoneVisionError { }
        let schema = try JSONSerialization.jsonObject(with: PhonePlannerResponse.schema(inspectOnly: false)) as! [String: Any]
        let properties = schema["properties"] as! [String: Any]
        let variants = (properties["decision"] as! [String: Any])["anyOf"] as! [[String: Any]]
        try check(!variants.contains { variant in
            let fields = variant["properties"] as! [String: Any]
            return (fields["kind"] as! [String: Any])["enum"] as? [String] == ["home"]
        }, "Schema advertises the unsupported Home gesture")
        let current = browserFrame(date: Date(timeIntervalSince1970: 100))
        let before = browserFrame(date: Date(timeIntervalSince1970: 98))
        let foreign = browserFrame(source: "SR2", date: Date(timeIntervalSince1970: 99))
        let future = browserFrame(date: Date(timeIntervalSince1970: 101))
        let steps: [PhoneVisionStep] = [
            .init(id: UUID(), number: 1, action: "Home", detail: "untrusted old explanation", capturedAt: before.capturedAt,
                  input: .home, beforeFrame: before, afterFrame: current, screenChanged: true),
            .init(id: UUID(), number: 2, action: "Tap", detail: "untrusted old explanation", capturedAt: before.capturedAt,
                  input: .tap(0.5, 0.5), beforeFrame: foreign, afterFrame: future, screenChanged: false)
        ]
        let images = PhonePlannerContext.images(frame: current, history: steps)
        try check(images.map { $0.1.id } == [before.id, current.id], "Foreign/future/duplicate images leaked into the request")
        try check(images.last?.0.hasPrefix("CURRENT SCREEN") == true, "The current screen must be attached last")

        let binary = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
        let config = CodexPhonePlanner.Configuration(executable: binary)
        _ = try await CodexPhonePlanner.nextDecision(goal: "test-custom-model", frame: current, history: [],
            configuration: .init(executable: binary, model: "custom-vision-model"))
        async let first = CodexPhonePlanner.nextDecision(goal: "Open TikTok", frame: current, history: steps, configuration: config)
        async let second = CodexPhonePlanner.nextDecision(goal: "Open Maps", frame: foreign, history: [], configuration: config)
        let decisions = try await [first, second]
        var directories: [String] = []
        for decision in decisions {
            guard case .action(.press(.assistiveTouch), let path) = decision else { throw Failure.assertion("CLI output was not decoded into AssistiveTouch") }
            directories.append(path)
            try check(!FileManager.default.fileExists(atPath: path), "Temporary phone data survived the request")
        }
        try check(Set(directories).count == 2, "Concurrent phones shared an output directory")
        let screen = try await CodexPhonePlanner.inspectScreen(frame: current, configuration: config)
        try check(screen.state == .appSwitcher && screen.appCardsVisible, "Inspection depended on a UI-TARS model or action response")
        for goal in ["test-cli-exit", "test-cli-missing", "test-cli-malformed", "test-cli-oversized"] {
            do {
                _ = try await CodexPhonePlanner.nextDecision(goal: goal, frame: current, history: [], configuration: config)
                throw Failure.assertion("Invalid CLI result was accepted for \(goal)")
            } catch let error as PhoneVisionError {
                try check(!error.localizedDescription.contains("secret-fixture"), "CLI diagnostics leaked into the UI")
            }
        }
        let existing = try temporaryRequests()
        let pending = Task { try await CodexPhonePlanner.nextDecision(goal: "test-cli-wait", frame: current, history: [], configuration: config) }
        for _ in 0..<100 {
            if try temporaryRequests() != existing { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        pending.cancel()
        do { _ = try await pending.value; throw Failure.assertion("Cancelled CLI returned a phone action") }
        catch is CancellationError { }
        try check(try temporaryRequests() == existing, "Cancelled request left screenshots behind")
        do {
            _ = try await CodexPhonePlanner.nextDecision(goal: "test-cli-wait", frame: current, history: [],
                configuration: .init(executable: binary, timeout: 0.3))
            throw Failure.assertion("CLI timeout was ignored")
        } catch PhonePlannerProcessError.timedOut { }
        try check(try temporaryRequests() == existing, "Timed-out request left screenshots behind")
        try check(CodexPhonePlanner.findExecutable(environment: ["SHORTREEL_CODEX_PATH": binary.path], home: binary.deletingLastPathComponent()) == binary,
            "Explicit executable override was ignored")
        try check(CodexPhonePlanner.findExecutable(environment: ["SHORTREEL_CODEX_PATH": "/missing/codex"], home: binary.deletingLastPathComponent()) == nil,
            "Invalid override silently selected a different binary")
        try check(PhoneVisionProvider(rawValue: "astra") == .codex, "Codex selection cannot be persisted")
        try check(PhoneVisionProvider.defaultProvider == .codex, "Codex must be the default screenshot planner")
        let finderEnvironment = PhonePlannerProcess.environment(["PATH": "/usr/bin:/bin", "HOME": "/Users/example",
            "CODEX_HOME": "/Users/example/.codex", "CODEX_THREAD_ID": "other-phone", "UNRELATED_SECRET": "secret-fixture"], executable: binary, authenticationKeys: ["CODEX_HOME"])
        try check(finderEnvironment["PATH"]?.contains("/opt/homebrew/bin") == true, "Finder launches cannot find the CLI's Node runtime")
        try check(finderEnvironment["CODEX_HOME"] == "/Users/example/.codex" && finderEnvironment["CODEX_THREAD_ID"] == nil
            && finderEnvironment["UNRELATED_SECRET"] == nil, "CLI authentication or parent-session isolation changed")
        if ProcessInfo.processInfo.environment["SHORTREEL_CODEX_SMOKE"] == "1" {
            let live = browserFrame()
            let decision = try await CodexPhonePlanner.nextDecision(goal: "Open the TikTok app", frame: live, history: [])
            switch decision {
            case .action(.tap, _), .action(.press(.assistiveTouch), _): break
            default: throw Failure.assertion("Real Codex did not use AssistiveTouch to leave a browser: \(decision)")
            }
            let observed = try await CodexPhonePlanner.inspectScreen(frame: live)
            try check(observed.state == .foregroundApp && !observed.appCardsVisible, "Real Codex misclassified the generated browser screenshot")
            print("Codex live CLI smoke passed: browser → AssistiveTouch decision and browser screen verification; no phone inputs sent")
        }
        print("Codex planner tests passed: actions, malformed results, app navigation, CLI wiring, concurrent phone isolation, cleanup, cancellation, timeout, and provider selection")
    }

    static func decoderTests() throws {
        let reason = "Visible target"
        let examples: [([String: Any], PhoneVisionDecision)] = [
            (["kind": "tap", "x": 0.1, "y": 0.2], .action(.tap(0.1, 0.2), reason: reason)),
            (["kind": "doubleTap", "x": 0.1, "y": 0.2], .action(.doubleTap(0.1, 0.2), reason: reason)),
            (["kind": "longPress", "x": 0.1, "y": 0.2, "seconds": 0.6], .action(.longPress(0.1, 0.2, seconds: 0.6), reason: reason)),
            (["kind": "drag", "x": 0.5, "y": 0.6, "endX": 0.5, "endY": 0.02, "duration": 0.16, "pressDuration": 0, "holdDuration": 0],
             .action(.timedDrag(0.5, 0.6, 0.5, 0.02, duration: 0.16, pressDuration: 0, holdDuration: 0), reason: reason)),
            (["kind": "swipe", "direction": "down"], .action(.swipe(.down), reason: reason)),
            (["kind": "typeText", "text": "TikTok"], .action(.typeText("TikTok"), reason: reason)),
            (["kind": "wait", "seconds": 0.5], .wait(seconds: 0.5, reason: reason)),
            (["kind": "finished"], .finished(reason)), (["kind": "needsInput"], .needsInput(reason))
        ] + PhoneKey.allCases.map { (["kind": "press", "key": $0.rawValue], .action(.press($0), reason: reason)) }
        for (fields, expected) in examples {
            let data = try response(fields.merging(["reason": reason]) { _, new in new })
            try check(try PhonePlannerResponse.decision(from: data, goal: "Use the visible interface") == expected, "Action changed during decoding")
        }
        let size = CGSize(width: 480, height: 1040)
        let units: [([String: Any], PhoneVisionDecision)] = [
            (["kind": "tap", "x": 9, "y": 96], .action(.tap(0.09, 0.96), reason: reason)),
            (["kind": "tap", "x": 48, "y": 988], .action(.tap(0.1, 0.95), reason: reason)),
            (["kind": "longPress", "x": 240, "y": 520, "seconds": 0.6], .action(.longPress(0.5, 0.5, seconds: 0.6), reason: reason)),
            (["kind": "drag", "x": 50, "y": 60, "endX": 50, "endY": 2, "duration": 0.16, "pressDuration": 0, "holdDuration": 0],
             .action(.timedDrag(0.5, 0.6, 0.5, 0.02, duration: 0.16, pressDuration: 0, holdDuration: 0), reason: reason)),
            (["kind": "drag", "x": 240, "y": 624, "endX": 240, "endY": 20.8, "duration": 0.16, "pressDuration": 0, "holdDuration": 0],
             .action(.timedDrag(0.5, 0.6, 0.5, 0.02, duration: 0.16, pressDuration: 0, holdDuration: 0), reason: reason)),
        ]
        for (fields, expected) in units {
            let data = try response(fields.merging(["reason": reason]) { _, new in new })
            let decoded = try PhonePlannerResponse.decision(from: data, goal: "Use the visible interface", imageSize: size)
            guard case .action(let action, _) = decoded, case .action(let wanted, _) = expected, action.isClose(to: wanted) else {
                throw Failure.assertion("Coordinates in percent or pixels were not normalized: \(decoded)")
            }
        }
        try check((try? PhonePlannerResponse.decision(from: response(["kind": "tap", "x": 48, "y": 988, "reason": reason]),
            goal: "Use the visible interface")) == nil, "Pixel coordinates were accepted without an image size")
        let schema = try JSONSerialization.jsonObject(with: PhonePlannerResponse.schema(inspectOnly: false)) as! [String: Any]
        let tap = ((schema["properties"] as! [String: Any])["decision"] as! [String: Any])["anyOf"] as! [[String: Any]]
        let coordinate = tap.compactMap { ($0["properties"] as! [String: Any])["x"] as? [String: Any] }.first
        try check((coordinate?["description"] as? String)?.contains("0 to 1") == true, "Schema does not state the coordinate unit")
        let invalid: [[String: Any]] = [
            ["kind": "openApp", "text": "TikTok"], ["kind": "tap", "x": -0.2, "y": 0.5],
            ["kind": "tap", "x": 500, "y": 200], ["kind": "tap", "x": 40, "y": 2000],
            ["kind": "tap", "x": true, "y": 0.5], ["kind": "tap", "x": NSNull(), "y": 0.5], ["kind": "tap", "x": 0.5],
            ["kind": "home", "text": "unexpected extra action"], ["kind": "swipe", "direction": "north"],
            ["kind": "press", "key": "launchApp"], ["kind": "wait", "seconds": 20],
            ["kind": "longPress", "x": 0.5, "y": 0.5, "seconds": 0.1],
            ["kind": "typeText", "text": "hello\nworld"], ["kind": "typeText", "text": "😀"],
            ["kind": "typeText", "text": String(repeating: "a", count: 101)]
        ]
        for fields in invalid {
            try rejects(try response(fields.merging(["reason": reason]) { _, new in new }))
        }
        try rejects(Data("not JSON".utf8))
        try rejects(try response(["kind": "home", "reason": " "]))
        try rejects(try response(["kind": "finished", "reason": reason], state: "home"), goal: "Open TikTok")
        try rejects(try response(["kind": "finished", "reason": reason], state: "appSwitcher"), goal: "Open TikTok")
        for (goal, x, y) in [("Open TikTok", 0.61, 0.92), ("Open Instagram", 0.83, 0.92), ("Open Maps", 0.15, 0.71)] {
            try check(try PhonePlannerResponse.decision(from: response(["kind": "tap", "x": x, "y": y, "reason": reason], state: "home"), goal: goal)
                == .action(.tap(x, y), reason: reason), "Visible app icon tap was blocked or its coordinates changed")
        }
        try rejects(try response(["kind": "typeText", "text": "TikTok", "reason": reason], state: "home"), goal: "Open TikTok")
        try rejects(try response(["kind": "home", "reason": reason], state: "home"), goal: "Open TikTok")
        for state in ["foregroundApp", "assistiveTouch", "unknown"] {
            try rejects(try response(["kind": "home", "reason": reason], state: state), goal: "Go Home")
        }
        for (state, x, y) in [("foregroundApp", 0.89, 0.05), ("assistiveTouch", 0.5, 0.7)] {
            try check(try PhonePlannerResponse.decision(from: response(["kind": "tap", "x": x, "y": y, "reason": reason], state: state), goal: "Go Home")
                == .action(.tap(x, y), reason: reason), "AssistiveTouch Home navigation rejected an observed control")
        }
        try check(try PhonePlannerResponse.decision(from: response(["kind": "typeText", "text": "TikTok", "reason": reason], state: "spotlight"), goal: "Open TikTok")
            == .action(.typeText("TikTok"), reason: reason), "Spotlight fallback could not type the app name")
        try rejects(try response(["kind": "press", "key": "appSwitcher", "reason": reason], state: "appSwitcher"))
        try rejects(try response(["kind": "tap", "x": 0.5, "y": 0.5, "reason": reason], state: "unknown"))
        try check(try PhonePlannerResponse.decision(from: response(["kind": "press", "key": "assistiveTouch", "reason": reason], state: "unknown"), goal: "Open TikTok")
            == .action(.press(.assistiveTouch), reason: reason), "Unclassified browser could not recover through AssistiveTouch")
        try check(try PhonePlannerResponse.decision(from: response(["kind": "swipe", "direction": "down", "reason": reason], state: "home"), goal: "Open TikTok")
            == .action(.swipe(.down), reason: reason), "Home could not advance toward Spotlight")
        var contradictory = try JSONSerialization.jsonObject(with: response(["kind": "home", "reason": reason])) as! [String: Any]
        contradictory["screen"] = ["state": "appSwitcher", "appCardsVisible": false, "evidence": "Safari"]
        try rejects(try JSONSerialization.data(withJSONObject: contradictory))
    }

    static func rejects(_ data: Data, goal: String = "Use the phone") throws {
        do { _ = try PhonePlannerResponse.decision(from: data, goal: goal); throw Failure.assertion("Invalid phone response accepted") }
        catch is PhoneVisionError { }
    }

    static func temporaryRequests() throws -> Set<String> {
        Set(try FileManager.default.contentsOfDirectory(atPath: FileManager.default.temporaryDirectory.path).filter { $0.hasPrefix("shortreel-codex-") })
    }

    static func fakeCLI() throws {
        let args = CommandLine.arguments
        func argument(_ flag: String) throws -> String {
            guard let index = args.firstIndex(of: flag), index + 1 < args.count else { throw Failure.assertion("Missing CLI flag \(flag)") }
            return args[index + 1]
        }
        try check(try argument("--sandbox") == "read-only", "Wrong sandbox")
        try check(args.contains("--ignore-user-config") && args.contains("--ephemeral") && args.last == "-", "CLI request is not isolated or stdin driven")
        try check(args.contains("approval_policy=\"never\"") && args.contains("project_doc_max_bytes=0"), "Unexpected interactive/config behavior")
        let instructions = args.first { $0.hasPrefix("model_instructions_file=") } ?? ""
        try check(!instructions.contains("\\/"), "JSON slash escapes are not valid in TOML paths")
        try check(args.contains("shell_tool") && args.contains("plugins") && args.contains("hooks") && args.contains("multi_agent"), "Unexpected CLI tools")
        let prompt = String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self)
        try check(try argument("--model") == (prompt.contains("test-custom-model") ? "custom-vision-model" : "gpt-6-astra"), "Selected model was not forwarded")
        let instructionPath = try argument("--cd") + "/instructions.txt"
        let expectedInstructions = prompt.contains(PhonePlannerContext.inspectionPrompt)
            ? PhonePlannerContext.inspectionInstructions : PhonePlannerContext.instructions
        try check(try String(contentsOfFile: instructionPath, encoding: .utf8) == expectedInstructions,
            "Codex did not use the shared instructions")
        try check(prompt.contains("CURRENT SCREEN") && !prompt.contains("untrusted old explanation"), "Missing current screen or leaked prior reasoning")
        let directory = try argument("--cd")
        let images = args.indices.filter { args[$0] == "--image" }.map { args[$0 + 1] }
        try check(!images.isEmpty && images.allSatisfy { $0.hasPrefix(directory + "/") }, "Phone images escaped their invocation directory")
        for image in images {
            try check((try FileManager.default.attributesOfItem(atPath: image)[.posixPermissions] as? NSNumber)?.intValue == 0o600, "Screenshot permissions changed")
        }
        let schema = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: argument("--output-schema")))) as! [String: Any]
        let output = URL(fileURLWithPath: try argument("--output-last-message"))
        if prompt.contains("test-cli-exit") {
            FileHandle.standardError.write(Data("secret-fixture".utf8)); exit(17)
        }
        if prompt.contains("test-cli-missing") { print("{\"kind\":\"home\"}"); return }
        if prompt.contains("test-cli-malformed") { try Data("bad JSON".utf8).write(to: output); return }
        if prompt.contains("test-cli-oversized") { try Data(repeating: 32, count: 65_537).write(to: output); return }
        if prompt.contains("test-cli-wait") { while true { sleep(1) } }
        let inspectOnly = (schema["properties"] as! [String: Any])["decision"] == nil
        let data = try inspectOnly ? response(state: "appSwitcher") : response(["kind": "press", "key": "assistiveTouch", "reason": directory])
        try data.write(to: output)
        print("Diagnostic stdout is not the final JSON response")
    }
}

private extension PhonePromptAction {
    func isClose(to other: PhonePromptAction) -> Bool {
        func near(_ a: Double, _ b: Double) -> Bool { abs(a - b) < 0.001 }
        switch (self, other) {
        case (.tap(let x, let y), .tap(let x2, let y2)): return near(x, x2) && near(y, y2)
        case (.longPress(let x, let y, let s), .longPress(let x2, let y2, let s2)): return near(x, x2) && near(y, y2) && near(s, s2)
        case (.timedDrag(let x, let y, let ex, let ey, let d, let p, let h), .timedDrag(let x2, let y2, let ex2, let ey2, let d2, let p2, let h2)):
            return near(x, x2) && near(y, y2) && near(ex, ex2) && near(ey, ey2) && near(d, d2) && near(p, p2) && near(h, h2)
        default: return self == other
        }
    }
}
