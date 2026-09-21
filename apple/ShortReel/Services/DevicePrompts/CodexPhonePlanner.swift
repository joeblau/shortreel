import Foundation

/// Codex supplies vision decisions; ShortReel alone sends inputs to the phone.
/// Each invocation is ephemeral and owns its files, so concurrent phones never
/// share a CLI conversation, screenshot, or output path.
enum CodexPhonePlanner {
    static let defaultModel = "gpt-6-astra"

    struct Configuration: Sendable {
        let executable: URL
        var environment: [String: String] = ProcessInfo.processInfo.environment
        var timeout: TimeInterval = 90
        var model: String = defaultModel
    }

    static var executableURL: URL? {
        findExecutable(environment: ProcessInfo.processInfo.environment,
                       home: FileManager.default.homeDirectoryForCurrentUser)
    }

    static func findExecutable(environment: [String: String], home: URL) -> URL? {
        if let override = environment["SHORTREEL_CODEX_PATH"] {
            guard override.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: override) else { return nil }
            return URL(fileURLWithPath: override)
        }
        let directories = (environment["PATH"] ?? "").split(separator: ":").map(String.init)
            + [".bun/bin", ".local/bin", ".cargo/bin"].map { home.appendingPathComponent($0).path }
            + ["/opt/homebrew/bin", "/usr/local/bin", "/Applications/Codex.app/Contents/Resources"]
        return directories.filter { $0.hasPrefix("/") }.map { URL(fileURLWithPath: $0).appendingPathComponent("codex") }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    static var isInstalled: Bool { executableURL != nil }
    static var unavailabilityReason: String? {
        isInstalled ? nil : "Install the Codex CLI and run ‘codex login’ in Terminal to use Codex."
    }

    private static func configuration(model: String) throws -> Configuration {
        guard let executable = executableURL else {
            throw PhoneVisionError.unavailable(unavailabilityReason ?? "The Codex CLI is unavailable.")
        }
        return .init(executable: executable, model: model)
    }

    static func nextDecision(goal: String, frame: PhoneScreenFrame, history: [PhoneVisionStep], model: String = defaultModel) async throws -> PhoneVisionDecision {
        try await nextDecision(goal: goal, frame: frame, history: history, configuration: configuration(model: model))
    }

    static func nextDecision(goal: String, frame: PhoneScreenFrame, history: [PhoneVisionStep],
                             configuration: Configuration) async throws -> PhoneVisionDecision {
        guard !goal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              goal.count <= DevicePromptPlanner.maximumPromptLength else {
            throw PhoneVisionError.invalidDecision("Codex needs a short phone task.")
        }
        let prompt = PhonePlannerContext.prompt(goal: goal, history: history)
        let data = try await request(prompt: prompt, frame: frame, history: history,
            schema: PhonePlannerResponse.schema(inspectOnly: false), configuration: configuration)
        return try PhonePlannerResponse.decision(from: data, goal: goal)
    }

    static func inspectScreen(frame: PhoneScreenFrame, model: String = defaultModel) async throws -> PhoneScreenObservation {
        try await inspectScreen(frame: frame, configuration: configuration(model: model))
    }

    static func inspectScreen(frame: PhoneScreenFrame, configuration: Configuration) async throws -> PhoneScreenObservation {
        let data = try await request(prompt: PhonePlannerContext.inspectionPrompt,
            frame: frame, history: [], schema: PhonePlannerResponse.schema(inspectOnly: true), configuration: configuration)
        return try PhonePlannerResponse.observation(from: data)
    }

    private static func request(prompt: String, frame: PhoneScreenFrame, history: [PhoneVisionStep],
                                schema: Data, configuration: Configuration) async throws -> Data {
        try Task.checkCancellation()
        let files = FileManager.default
        let directory = files.temporaryDirectory.appendingPathComponent("shortreel-codex-\(UUID().uuidString)", isDirectory: true)
        try files.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? files.removeItem(at: directory) }
        func write(_ data: Data, name: String) throws -> URL {
            let url = directory.appendingPathComponent(name)
            guard files.createFile(atPath: url.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
                throw PhoneVisionError.unavailable("Couldn’t prepare Codex’s screenshot request.")
            }
            return url
        }
        let instructions = try write(Data(PhonePlannerContext.instructions.utf8), name: "instructions.txt")
        let schemaURL = try write(schema, name: "response.schema.json")
        let output = directory.appendingPathComponent("response.json")
        var imageURLs: [URL] = []
        var labels: [String] = []
        for (index, entry) in PhonePlannerContext.images(frame: frame, history: history).enumerated() {
            let (label, image) = entry
            guard !image.jpegData.isEmpty, image.jpegData.count <= 10_000_000,
                  (1...8192).contains(image.pixelWidth), (1...8192).contains(image.pixelHeight),
                  image.cgImage.width == image.pixelWidth, image.cgImage.height == image.pixelHeight else {
                throw PhoneVisionError.invalidDecision("Codex needs valid phone screenshots.")
            }
            imageURLs.append(try write(image.jpegData, name: "screen-\(index).jpg"))
            labels.append("Image \(index + 1): \(label) (\(image.pixelWidth) × \(image.pixelHeight)).")
        }
        let arguments = try arguments(directory: directory, instructions: instructions, schema: schemaURL,
                                      output: output, images: imageURLs, model: configuration.model)
        // Retain CLI authentication, but do not inherit this parent agent's
        // thread attribution or logging. Never read or copy credential contents.
        let environment = PhonePlannerProcess.environment(configuration.environment, executable: configuration.executable, authenticationKeys: ["CODEX_HOME"])
        let result = try await PhonePlannerProcess.run(executable: configuration.executable, arguments: arguments,
            directory: directory, input: Data((prompt + "\nAttached images, in order:\n" + labels.joined(separator: "\n")).utf8),
            environment: environment, timeout: configuration.timeout, maximumOutputBytes: 1_000_000)
        try Task.checkCancellation()
        guard result.exitCode == 0 else {
            // CLI diagnostics can contain prompts or credentials; never echo them.
            throw PhoneVisionError.unavailable("The Codex CLI exited with status \(result.exitCode). Run ‘codex login’ and check that ‘codex exec’ works in Terminal. A current Codex CLI is required.")
        }
        guard let handle = try? FileHandle(forReadingFrom: output) else {
            throw PhoneVisionError.invalidDecision("Codex returned no final phone decision.")
        }
        defer { try? handle.close() }
        let data = try handle.read(upToCount: 65_537) ?? Data()
        guard !data.isEmpty, data.count <= 65_536 else {
            throw PhoneVisionError.invalidDecision("Codex returned an empty or oversized phone decision.")
        }
        return data
    }

    static func arguments(directory: URL, instructions: URL, schema: URL, output: URL, images: [URL], model: String = defaultModel) throws -> [String] {
        guard PhoneVisionProvider.isValidModel(model) else { throw PhoneVisionError.invalidDecision("Choose a valid Codex model ID.") }
        // JSON string encoding without escaped slashes is valid TOML here.
        // These are literal argv entries, never interpolated shell commands.
        let encoder = JSONEncoder()
        encoder.outputFormatting = .withoutEscapingSlashes
        let instructionPath = String(decoding: try encoder.encode(instructions.path), as: UTF8.self)
        var args = ["exec", "--model", model, "--ephemeral", "--skip-git-repo-check", "--ignore-user-config",
                    "--sandbox", "read-only", "--color", "never", "--cd", directory.path,
                    "--output-schema", schema.path, "--output-last-message", output.path,
                    "-c", "approval_policy=\"never\"", "-c", "model_reasoning_effort=\"low\"",
                    "-c", "model_instructions_file=\(instructionPath)", "-c", "project_doc_max_bytes=0",
                    "-c", "web_search=\"disabled\""]
        for feature in ["shell_tool", "unified_exec", "shell_snapshot", "apps", "plugins", "hooks", "multi_agent",
                        "browser_use", "computer_use", "image_generation", "memories", "skill_search"] {
            args += ["--disable", feature]
        }
        args += ["--enable", "skip_host_skill_discovery"]
        for image in images { args += ["--image", image.path] }
        return args + ["-"]
    }

}
