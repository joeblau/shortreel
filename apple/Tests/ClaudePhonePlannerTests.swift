import AppKit
import Darwin
import Foundation

// swiftc -swift-version 6 ShortReel/Services/DevicePrompts/{DevicePromptPlan,DevicePromptPlanner,PhoneVisionTypes,PhonePlannerProcess,PhonePlannerContext,PhonePlannerResponse,ClaudePhonePlanner,PhoneVisionProvider}.swift Tests/ClaudePhonePlannerTests.swift -o /tmp/shortreel-claude-tests
// SHORTREEL_CLAUDE_SMOKE=1 /tmp/shortreel-claude-tests runs synthetic-image inference only; no phone input.
@main
struct ClaudePhonePlannerTests {
    enum Failure: Error { case assertion(String) }
    static func check(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
        if try !value() { throw Failure.assertion(message) }
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
        if CommandLine.arguments.dropFirst().first == "--print" { try fakeCLI(); return }
        let current = browserFrame(date: Date(timeIntervalSince1970: 100))
        let foreign = browserFrame(source: "SR2", date: Date(timeIntervalSince1970: 99))
        let history: [PhoneVisionStep] = [
            .init(id: UUID(), number: 1, action: "Tap", detail: "untrusted old explanation", capturedAt: foreign.capturedAt,
                  beforeFrame: foreign)
        ]
        let input = try ClaudePhonePlanner.input(prompt: "Task", frame: current, history: history)
        let message = try JSONSerialization.jsonObject(with: input) as! [String: Any]
        let content = (message["message"] as! [String: Any])["content"] as! [[String: Any]]
        try check(content.filter { $0["type"] as? String == "image" }.count == 1, "Foreign screenshot leaked")
        try check(content[content.count - 2]["text"] as? String == "CURRENT SCREEN — use this image for all coordinates and completion claims (480 × 1040).", "Current image is not last")
        let watchingStart = browserFrame(date: Date(timeIntervalSince1970: 1))
        var playbackHistory = history
        playbackHistory[0].playbackStartFrame = watchingStart
        let playbackImages = PhonePlannerContext.images(frame: current, history: playbackHistory)
        try check(playbackImages.count == 2 && playbackImages.first?.1.id == watchingStart.id
            && playbackImages.last?.1.id == current.id, "Watching-start evidence was lost or reordered")
        try check(playbackImages.first?.0.contains("99 seconds") == true, "Playback image timing is missing")
        playbackHistory[0].playbackStartFrame = foreign
        try check(PhonePlannerContext.images(frame: current, history: playbackHistory).count == 1,
            "Another phone's watching-start image leaked")
        let binary = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
        let config = ClaudePhonePlanner.Configuration(executable: binary, model: "opus")
        async let first = ClaudePhonePlanner.nextDecision(goal: "Open TikTok", frame: current, history: history, configuration: config)
        async let second = ClaudePhonePlanner.nextDecision(goal: "Open Maps", frame: foreign, history: [], configuration: config)
        let decisions = try await [first, second]
        var directories: [String] = []
        for decision in decisions {
            guard case .action(.press(.assistiveTouch), let path) = decision else { throw Failure.assertion("Unexpected action") }
            directories.append(path)
            try check(!FileManager.default.fileExists(atPath: path), "Temporary instructions survived")
        }
        try check(Set(directories).count == 2, "Phones shared a request directory")
        let observation = try await ClaudePhonePlanner.inspectScreen(frame: current, configuration: config)
        try check(observation.state == .foregroundApp, "Inspection did not use the shared schema")
        for goal in ["test-exit", "test-missing", "test-error", "test-duplicate", "test-malformed", "test-oversized", "test-invalid-action"] {
            do {
                _ = try await ClaudePhonePlanner.nextDecision(goal: goal, frame: current, history: [], configuration: config)
                throw Failure.assertion("Invalid response accepted for \(goal)")
            } catch let error as PhoneVisionError {
                try check(!error.localizedDescription.contains("secret-fixture"), "Raw CLI diagnostics leaked")
            }
        }
        let before = try temporaryRequests()
        do {
            _ = try await ClaudePhonePlanner.nextDecision(goal: "test-wait", frame: current, history: [],
                configuration: .init(executable: binary, timeout: 0.3, model: "opus"))
            throw Failure.assertion("Timeout ignored")
        } catch PhonePlannerProcessError.timedOut { }
        try check(try before == temporaryRequests(), "Timed-out request left files")
        let pending = Task { try await ClaudePhonePlanner.nextDecision(goal: "test-wait", frame: current, history: [], configuration: config) }
        for _ in 0..<100 {
            if try before != temporaryRequests() { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        pending.cancel()
        do { _ = try await pending.value; throw Failure.assertion("Cancelled call returned a decision") }
        catch is CancellationError { }
        try check(try before == temporaryRequests(), "Cancelled request left files")
        try check(ClaudePhonePlanner.findExecutable(environment: ["SHORTREEL_CLAUDE_PATH": binary.path], home: binary.deletingLastPathComponent()) == binary, "Override ignored")
        try check(ClaudePhonePlanner.findExecutable(environment: ["SHORTREEL_CLAUDE_PATH": "/missing/claude"], home: binary.deletingLastPathComponent()) == nil, "Invalid override used another executable")
        try check(PhoneVisionProvider(rawValue: "astra") == .codex && PhoneVisionProvider.codex.displayName == "Codex", "Saved Astra selection was lost")
        try check(PhoneVisionProvider.claude.defaultModel == "sonnet", "Claude default changed")
        try check(!PhoneVisionProvider.isValidModel("--bad") && !PhoneVisionProvider.isValidModel("bad model"), "Invalid model accepted")
        if ProcessInfo.processInfo.environment["SHORTREEL_CLAUDE_SMOKE"] == "1" {
            let live = browserFrame()
            let decision = try await ClaudePhonePlanner.nextDecision(goal: "Open the TikTok app", frame: live, history: [])
            switch decision {
            case .action(.tap, _), .action(.press(.assistiveTouch), _): break
            default: throw Failure.assertion("Live Claude failed browser navigation: \(decision)")
            }
            let observed = try await ClaudePhonePlanner.inspectScreen(frame: live)
            try check(observed.state == .foregroundApp && !observed.appCardsVisible, "Live Claude misclassified browser")
            print("Claude live smoke passed: screenshot navigation and inspection; no phone input sent")
        }
        print("Claude planner tests passed: image isolation, shared instructions/schema, model selection, CLI flags, final-output validation, cleanup, cancellation, and timeout")
    }

    static func temporaryRequests() throws -> Set<String> {
        Set(try FileManager.default.contentsOfDirectory(atPath: FileManager.default.temporaryDirectory.path).filter { $0.hasPrefix("shortreel-claude-") })
    }

    static func fakeCLI() throws {
        let args = CommandLine.arguments
        func argument(_ flag: String) throws -> String {
            guard let index = args.firstIndex(of: flag), index + 1 < args.count else { throw Failure.assertion("Missing flag \(flag)") }
            return args[index + 1]
        }
        try check(try argument("--model") == "opus", "Selected model not forwarded")
        try check(try argument("--tools").isEmpty && argument("--setting-sources").isEmpty, "Inherited tools/settings")
        for flag in ["--safe-mode", "--strict-mcp-config", "--disable-slash-commands", "--no-chrome", "--no-session-persistence"] {
            try check(args.contains(flag), "Missing isolation flag \(flag)")
        }
        try check(try argument("--permission-mode") == "dontAsk", "Interactive permissions enabled")
        let instructions = try argument("--system-prompt-file")
        try check(try String(contentsOfFile: instructions, encoding: .utf8) == PhonePlannerContext.instructions, "Provider instructions differ")
        try check((try FileManager.default.attributesOfItem(atPath: instructions)[.posixPermissions] as? NSNumber)?.intValue == 0o600, "Instruction permissions changed")
        let raw = FileHandle.standardInput.readDataToEndOfFile()
        let message = try JSONSerialization.jsonObject(with: raw) as! [String: Any]
        let content = (message["message"] as! [String: Any])["content"] as! [[String: Any]]
        let prompt = content.compactMap { $0["text"] as? String }.joined(separator: "\n")
        try check(prompt.contains("CURRENT SCREEN") && !prompt.contains("untrusted old explanation"), "Missing current image or inherited reasoning")
        try check(content.last?["type"] as? String == "image", "Current image not last")
        let image = content.last?["source"] as! [String: String]
        try check(image["media_type"] == "image/jpeg" && Data(base64Encoded: image["data"]!) != nil, "Invalid image source")
        let schema = try JSONSerialization.jsonObject(with: Data(argument("--json-schema").utf8)) as! [String: Any]
        let inspectOnly = (schema["properties"] as! [String: Any])["decision"] == nil
        try check(try JSONSerialization.data(withJSONObject: schema, options: [.sortedKeys]) == PhonePlannerResponse.schema(inspectOnly: inspectOnly), "Schema differs between providers")
        if prompt.contains("test-exit") { FileHandle.standardError.write(Data("secret-fixture".utf8)); exit(17) }
        if prompt.contains("test-wait") { while true { sleep(1) } }
        if prompt.contains("test-missing") { print("{} "); return }
        if prompt.contains("test-malformed") { print("not JSON"); return }
        var structured: [String: Any] = ["screen": ["state": "foregroundApp", "appCardsVisible": false, "evidence": "Visible browser"]]
        if !inspectOnly {
            structured["decision"] = ["kind": "press", "key": "assistiveTouch", "reason": FileManager.default.currentDirectoryPath]
        }
        if prompt.contains("test-invalid-action") { structured["decision"] = ["kind": "tap", "x": 2, "y": 0.5, "reason": "Invalid coordinate"] }
        if prompt.contains("test-oversized") { structured["padding"] = String(repeating: "x", count: 66_000) }
        let result: [String: Any] = ["type": "result", "subtype": prompt.contains("test-error") ? "error_max_turns" : "success",
            "is_error": prompt.contains("test-error"), "structured_output": structured]
        let output = String(decoding: try JSONSerialization.data(withJSONObject: result), as: UTF8.self)
        print("Diagnostic text must never become phone input")
        print(output)
        if prompt.contains("test-duplicate") { print(output) }
    }
}
