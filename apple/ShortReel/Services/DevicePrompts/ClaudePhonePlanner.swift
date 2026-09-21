import Foundation

/// Claude Code supplies one decision from attached images. ShortReel alone
/// executes phone inputs, using the same instructions and decoder as Codex.
enum ClaudePhonePlanner {
    static let defaultModel = "sonnet"

    struct Configuration: Sendable {
        let executable: URL
        var environment: [String: String] = ProcessInfo.processInfo.environment
        var timeout: TimeInterval = 90
        var model: String = defaultModel
    }

    static var executableURL: URL? {
        findExecutable(environment: ProcessInfo.processInfo.environment, home: FileManager.default.homeDirectoryForCurrentUser)
    }

    static func findExecutable(environment: [String: String], home: URL) -> URL? {
        if let override = environment["SHORTREEL_CLAUDE_PATH"] {
            guard override.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: override) else { return nil }
            return URL(fileURLWithPath: override)
        }
        let directories = (environment["PATH"] ?? "").split(separator: ":").map(String.init)
            + [".local/bin", ".bun/bin", ".npm-global/bin"].map { home.appendingPathComponent($0).path }
            + ["/opt/homebrew/bin", "/usr/local/bin"]
        return directories.filter { $0.hasPrefix("/") }.map { URL(fileURLWithPath: $0).appendingPathComponent("claude") }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    static var isInstalled: Bool { executableURL != nil }
    static var unavailabilityReason: String? {
        isInstalled ? nil : "Install Claude Code and run ‘claude auth login’ in Terminal to use Claude."
    }

    private static func configuration(model: String) throws -> Configuration {
        guard let executable = executableURL else {
            throw PhoneVisionError.unavailable(unavailabilityReason ?? "Claude Code is unavailable.")
        }
        return .init(executable: executable, model: model)
    }

    static func nextDecision(goal: String, frame: PhoneScreenFrame, history: [PhoneVisionStep], model: String = defaultModel) async throws -> PhoneVisionDecision {
        try await nextDecision(goal: goal, frame: frame, history: history, configuration: configuration(model: model))
    }

    static func nextDecision(goal: String, frame: PhoneScreenFrame, history: [PhoneVisionStep], configuration: Configuration) async throws -> PhoneVisionDecision {
        guard !goal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              goal.count <= DevicePromptPlanner.maximumPromptLength else {
            throw PhoneVisionError.invalidDecision("Claude needs a short phone task.")
        }
        let data = try await request(prompt: PhonePlannerContext.prompt(goal: goal, history: history), frame: frame,
            history: history, schema: PhonePlannerResponse.schema(inspectOnly: false), configuration: configuration)
        return try PhonePlannerResponse.decision(from: data, goal: goal,
            imageSize: CGSize(width: frame.pixelWidth, height: frame.pixelHeight))
    }

    static func inspectScreen(frame: PhoneScreenFrame, model: String = defaultModel) async throws -> PhoneScreenObservation {
        try await inspectScreen(frame: frame, configuration: configuration(model: model))
    }

    static func inspectScreen(frame: PhoneScreenFrame, configuration: Configuration) async throws -> PhoneScreenObservation {
        let data = try await request(prompt: PhonePlannerContext.inspectionPrompt,
            frame: frame, history: [], schema: PhonePlannerResponse.schema(inspectOnly: true), configuration: configuration)
        return try PhonePlannerResponse.observation(from: data)
    }

    static func arguments(instructions: URL, schema: Data, model: String) throws -> [String] {
        guard PhoneVisionProvider.isValidModel(model) else {
            throw PhoneVisionError.invalidDecision("Choose a valid Claude model ID or alias.")
        }
        return ["--print", "--model", model, "--effort", "low", "--input-format", "stream-json",
                "--output-format", "stream-json", "--verbose", "--json-schema", String(decoding: schema, as: UTF8.self),
                "--system-prompt-file", instructions.path, "--tools", "", "--safe-mode",
                "--settings", "{\"disableAllHooks\":true}", "--setting-sources", "",
                "--strict-mcp-config", "--mcp-config", "{\"mcpServers\":{}}",
                "--disable-slash-commands", "--no-chrome", "--permission-mode", "dontAsk",
                "--no-session-persistence", "--max-turns", "3"]
    }

    static func input(prompt: String, frame: PhoneScreenFrame?, history: [PhoneVisionStep]) throws -> Data {
        var content: [[String: Any]] = [["type": "text", "text": prompt]]
        let images = frame.map { PhonePlannerContext.images(frame: $0, history: history) } ?? []
        for (label, image) in images {
            guard !image.jpegData.isEmpty, image.jpegData.count <= 5_000_000,
                  (1...8192).contains(image.pixelWidth), (1...8192).contains(image.pixelHeight),
                  image.cgImage.width == image.pixelWidth, image.cgImage.height == image.pixelHeight else {
                throw PhoneVisionError.invalidDecision("Claude needs valid phone screenshots.")
            }
            content.append(["type": "text", "text": "\(label) (\(image.pixelWidth) × \(image.pixelHeight))."])
            content.append(["type": "image", "source": ["type": "base64", "media_type": "image/jpeg", "data": image.jpegData.base64EncodedString()]])
        }
        let message: [String: Any] = ["type": "user", "message": ["role": "user", "content": content], "parent_tool_use_id": NSNull()]
        var data = try JSONSerialization.data(withJSONObject: message, options: [.sortedKeys])
        data.append(0x0A)
        return data
    }

    /// Ignore diagnostics and intermediate text. Only one successful final
    /// result's structured_output can become phone input.
    static func response(from output: Data) throws -> Data {
        var final: [String: Any]?
        for line in output.split(separator: 0x0A) {
            guard let value = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  value["type"] as? String == "result" else { continue }
            guard final == nil else { throw invalidResponse() }
            final = value
        }
        guard let final, final["subtype"] as? String == "success", final["is_error"] as? Bool == false,
              let structured = final["structured_output"] as? [String: Any] else { throw invalidResponse() }
        let data = try JSONSerialization.data(withJSONObject: structured)
        guard data.count <= 65_536 else { throw invalidResponse() }
        return data
    }

    private static func invalidResponse() -> PhoneVisionError {
        .invalidDecision("Claude returned no valid final phone decision. Check ‘claude auth status’ and access to the selected model; a current Claude Code CLI is required.")
    }

    static func textResponse(prompt: String, instructions: String, schema: Data, model: String = defaultModel) async throws -> Data {
        try await request(prompt: prompt, frame: nil, history: [], schema: schema,
            configuration: configuration(model: model), instructionText: instructions)
    }

    private static func request(prompt: String, frame: PhoneScreenFrame?, history: [PhoneVisionStep], schema: Data,
                                configuration: Configuration, instructionText: String = PhonePlannerContext.instructions) async throws -> Data {
        try Task.checkCancellation()
        let files = FileManager.default
        let directory = files.temporaryDirectory.appendingPathComponent("shortreel-claude-\(UUID().uuidString)", isDirectory: true)
        try files.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? files.removeItem(at: directory) }
        let instructions = directory.appendingPathComponent("instructions.txt")
        guard files.createFile(atPath: instructions.path, contents: Data(instructionText.utf8), attributes: [.posixPermissions: 0o600]) else {
            throw PhoneVisionError.unavailable("Couldn’t prepare Claude’s screenshot request.")
        }
        var environment = PhonePlannerProcess.environment(configuration.environment, executable: configuration.executable,
            authenticationKeys: ["CLAUDE_CONFIG_DIR", "CLAUDE_CODE_OAUTH_TOKEN", "ANTHROPIC_API_KEY"])
        environment["DISABLE_AUTOUPDATER"] = "1"
        let result = try await PhonePlannerProcess.run(executable: configuration.executable,
            arguments: arguments(instructions: instructions, schema: schema, model: configuration.model), directory: directory,
            input: input(prompt: prompt, frame: frame, history: history), environment: environment,
            timeout: configuration.timeout, maximumOutputBytes: 1_000_000)
        try Task.checkCancellation()
        guard result.exitCode == 0 else {
            throw PhoneVisionError.unavailable("Claude Code exited with status \(result.exitCode). Run ‘claude auth login’ and check access to the selected model. A current Claude Code CLI is required.")
        }
        return try response(from: result.stdout)
    }
}
