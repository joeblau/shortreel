import Foundation

/// A single external process launch: an executable path plus literal argv.
struct ProcessInvocation: Sendable, Equatable {
    var executable: String
    var arguments: [String]
}

/// Captured result of a finished process.
struct ProcessResult: Sendable, Equatable {
    var stdout: String
    var stderr: String
    var exitCode: Int32
}

enum RunnerCommandError: Error, LocalizedError, Equatable {
    case failed(ProcessInvocation, exitCode: Int32, stderr: String)

    var errorDescription: String? {
        switch self {
        case .failed(let invocation, let exitCode, let stderr):
            let command = ([invocation.executable] + invocation.arguments).joined(separator: " ")
            let detail = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            return "`\(command)` exited \(exitCode)\(detail.isEmpty ? "" : ": \(detail)")"
        }
    }
}

/// Process execution seam. The supervisor and provisioning shell out to
/// go-ios and security(1) exclusively through this protocol so tests drive
/// them with a fake. `run` must terminate the process when the awaiting
/// task is cancelled — long-running children (tunnel, runtest, forward)
/// rely on cancellation as their stop signal.
protocol ProcessRunning: Sendable {
    func run(_ invocation: ProcessInvocation) async throws -> ProcessResult
}

extension ProcessRunning {
    /// Runs a one-shot command that must exit 0, throwing RunnerCommandError otherwise.
    @discardableResult
    func runChecked(_ invocation: ProcessInvocation) async throws -> ProcessResult {
        let result = try await run(invocation)
        guard result.exitCode == 0 else {
            throw RunnerCommandError.failed(invocation, exitCode: result.exitCode, stderr: result.stderr)
        }
        return result
    }
}

/// Production ProcessRunning over Foundation.Process.
struct SystemProcessRunner: ProcessRunning {
    func run(_ invocation: ProcessInvocation) async throws -> ProcessResult {
        try Task.checkCancellation()
        let handle = SystemProcessHandle(invocation: invocation)
        return try await withTaskCancellationHandler {
            try handle.start()
            let result = await handle.result()
            try Task.checkCancellation()
            return result
        } onCancel: {
            handle.terminate()
        }
    }
}

/// All Process state lives behind `lock` so the @Sendable cancellation
/// handler can touch it; hence unchecked Sendable.
private final class SystemProcessHandle: @unchecked Sendable {
    private let process = Process()
    private let stdoutPipe = Pipe()
    private let stderrPipe = Pipe()
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Int32, Never>?
    private var status: Int32?
    private var terminateRequested = false

    init(invocation: ProcessInvocation) {
        let searchPaths = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
            + [NSHomeDirectory() + "/.bun/bin", "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"]
        let executable = invocation.executable.contains("/") ? invocation.executable
            : searchPaths.map { $0 + "/" + invocation.executable }.first { FileManager.default.isExecutableFile(atPath: $0) } ?? invocation.executable
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = invocation.arguments
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        process.terminationHandler = { [weak self] process in
            self?.exited(process.terminationStatus)
        }
    }

    func start() throws {
        lock.lock()
        defer { lock.unlock() }
        guard !terminateRequested else { throw CancellationError() }
        try process.run()
    }

    func terminate() {
        lock.lock()
        terminateRequested = true
        let running = process.isRunning
        lock.unlock()
        if running { process.terminate() }
    }

    func result() async -> ProcessResult {
        async let stdout = Self.collect(stdoutPipe.fileHandleForReading)
        async let stderr = Self.collect(stderrPipe.fileHandleForReading)
        let status = await wait()
        return await ProcessResult(stdout: String(decoding: stdout, as: UTF8.self),
                                   stderr: String(decoding: stderr, as: UTF8.self),
                                   exitCode: status)
    }

    private func exited(_ exitCode: Int32) {
        lock.lock()
        if let continuation {
            self.continuation = nil
            lock.unlock()
            continuation.resume(returning: exitCode)
        } else {
            status = exitCode
            lock.unlock()
        }
    }

    private func wait() async -> Int32 {
        await withCheckedContinuation { continuation in
            lock.lock()
            if let status {
                self.status = nil
                lock.unlock()
                continuation.resume(returning: status)
            } else {
                self.continuation = continuation
                lock.unlock()
            }
        }
    }

    private static func collect(_ handle: FileHandle) async -> Data {
        var data = Data()
        do {
            for try await byte in handle.bytes {
                data.append(byte)
                if data.count > 262_144 { data.removeFirst(131_072) }
            }
        } catch {}
        return data
    }
}

/// Lifecycle states of one phone's on-device runner, surfaced on
/// `RunnerSupervisor.states`.
enum RunnerState: Sendable, Equatable {
    case starting
    case ready(localPort: UInt16)
    case restarting(attempt: Int)
    case failed(reason: String)
}

enum RunnerSupervisorError: Error, LocalizedError {
    case healthChecksExhausted(attempts: Int, lastError: String)

    var errorDescription: String? {
        switch self {
        case .healthChecksExhausted(let attempts, let lastError):
            "The runner did not answer /health after \(attempts) checks: \(lastError)"
        }
    }
}

/// The userspace tunnel seam, satisfied by GoIosTunnelDaemon in production.
protocol TunnelManaging: Sendable {
    func ensureRunning() async throws
}

/// Shared userspace RemotePairing tunnel daemon (`ios tunnel start
/// --userspace`, go-ios v1.3.x). One agent process serves every attached
/// phone, so all RunnerSupervisor instances share `.shared` instead of
/// spawning a tunnel per UDID. If the agent dies the next ensureRunning
/// relaunches it; the agent itself re-establishes per-device tunnels.
actor GoIosTunnelDaemon: TunnelManaging {
    static let shared = GoIosTunnelDaemon(processes: SystemProcessRunner())

    private let processes: ProcessRunning
    private let executable: String
    private var daemonTask: Task<Void, Never>?
    private var running = false

    init(processes: ProcessRunning, executable: String = "ios") {
        self.processes = processes
        self.executable = executable
    }

    func ensureRunning() async throws {
        if await isAvailable() { return }
        if !running {
            running = true
            let records = FileManager.default.homeDirectoryForCurrentUser
                .appending(path: "Library/Application Support/ShortReel/GoIOS", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: records, withIntermediateDirectories: true)
            daemonTask = Task { [processes, executable] in
                _ = try? await processes.run(ProcessInvocation(executable: executable,
                    arguments: ["tunnel", "start", "--userspace", "--pair-record-path", records.path]))
                await self.daemonExited()
            }
        }
        for _ in 0..<30 {
            try Task.checkCancellation()
            if await isAvailable() { return }
            try await Task.sleep(for: .milliseconds(500))
        }
        throw RunnerSupervisorError.healthChecksExhausted(attempts: 30, lastError: "go-ios tunnel daemon did not start")
    }

    private func isAvailable() async -> Bool {
        guard let result = try? await processes.run(ProcessInvocation(executable: executable, arguments: ["tunnel", "ls"])),
              result.exitCode == 0, let data = result.stdout.data(using: .utf8),
              (try? JSONSerialization.jsonObject(with: data)) is [Any] else { return false }
        return true
    }

    func stop() async {
        daemonTask?.cancel()
        await daemonTask?.value
        daemonTask = nil
        running = false
    }

    private func daemonExited() async {
        running = false
    }
}

/// Per-phone lifecycle manager for the on-device ShortReelRunner
/// (docs/phone-runner-design.md §Mac-side). Bring-up sequence: shared
/// userspace tunnel → `ios image auto` (DDI) → optional `ios install` of a
/// built runner product → `ios runtest` launching the UITests bundle via
/// testmanagerd → `ios forward` of the runner port → /health polling.
/// Thereafter a keepalive loop restarts the runner with exponential backoff
/// (capped at `Configuration.maxAttempts`) whenever health fails, covering
/// testmanagerd jetsam and tunnel drops.
///
/// Command lines follow go-ios v1.3.x (`runtest` is the generic XCUITest
/// launcher; `runxctest` takes an .xctestrun file and `runwda` is
/// WDA-specific). Command syntax is checked against go-ios 1.3.2.
actor RunnerSupervisor {
    struct Configuration: Sendable {
        var udid: String
        /// Built .app to install before launching; nil skips installation.
        var runnerProductPath: URL? = nil
        var uitestRunnerProductPath: URL? = nil
        var localPort: UInt16 = PhoneRunnerProtocol.port
        var appBundleID = "com.joeblau.shortreel.runner"
        var testRunnerBundleID = "com.joeblau.shortreel.runner.uitests.xctrunner"
        var xctestConfig = "ShortReelRunnerUITests.xctest"
        var goIosExecutable = "ios"
        var imageCacheDirectory = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Caches/ShortReel/DeveloperImages", directoryHint: .isDirectory)
        var healthCheckAttempts = 15
        var healthPollInterval: TimeInterval = 2
        var maxAttempts = 5
        var backoff: [TimeInterval] = [1, 2, 4, 8, 16]
        var sleep: @Sendable (TimeInterval) async throws -> Void = { try await Task.sleep(for: .seconds($0)) }

        init(udid: String) {
            self.udid = udid
        }
    }

    /// Single-consumer stream of lifecycle states. Finishes when the
    /// supervisor fails permanently or `stop()` is called.
    nonisolated let states: AsyncStream<RunnerState>

    private let continuation: AsyncStream<RunnerState>.Continuation
    private let configuration: Configuration
    private let processes: ProcessRunning
    private let tunnel: TunnelManaging
    private let client: PhoneRunnerServing
    private var lifecycleTask: Task<Void, Never>?
    private var childFailure: String?
    private var childTasks: [Task<Void, Never>] = []

    init(configuration: Configuration, processes: ProcessRunning, tunnel: TunnelManaging, client: PhoneRunnerServing) {
        self.configuration = configuration
        self.processes = processes
        self.tunnel = tunnel
        self.client = client
        (states, continuation) = AsyncStream.makeStream(of: RunnerState.self)
    }

    /// Convenience initializer using the shared tunnel daemon and a client
    /// for the configured forwarded port.
    init(configuration: Configuration, processes: ProcessRunning = SystemProcessRunner()) {
        self.init(configuration: configuration,
                  processes: processes,
                  tunnel: GoIosTunnelDaemon.shared,
                  client: RunnerClient(port: configuration.localPort))
    }

    func start() {
        guard lifecycleTask == nil else { return }
        lifecycleTask = Task { [weak self] in await self?.runLifecycle() }
    }

    func stop() async {
        lifecycleTask?.cancel()
        await lifecycleTask?.value
        lifecycleTask = nil
    }

    private func runLifecycle() async {
        emit(.starting)
        var attempt = 0
        while !Task.isCancelled {
            do {
                try await bringUp()
                attempt = 0
                emit(.ready(localPort: configuration.localPort))
                try await monitorHealth()
            } catch is CancellationError {
                break
            } catch {
                attempt += 1
                await teardownChildren()
                guard attempt < configuration.maxAttempts else {
                    emit(.failed(reason: describe(error)))
                    break
                }
                emit(.restarting(attempt: attempt))
                do {
                    let delay = configuration.backoff[min(attempt, configuration.backoff.count) - 1]
                    try await configuration.sleep(delay)
                } catch {
                    break
                }
            }
        }
        await teardownChildren()
        continuation.finish()
    }

    private func bringUp() async throws {
        try await tunnel.ensureRunning()
        let ios = configuration.goIosExecutable
        try FileManager.default.createDirectory(at: configuration.imageCacheDirectory, withIntermediateDirectories: true)
        try await RunnerImageMountQueue.shared.mount(processes: processes, invocation: ProcessInvocation(executable: ios,
            arguments: ["image", "auto", "--basedir", configuration.imageCacheDirectory.path, "--udid", configuration.udid]))
        for productPath in [configuration.runnerProductPath, configuration.uitestRunnerProductPath].compactMap({ $0 }) {
            try await processes.runChecked(ProcessInvocation(executable: ios,
                arguments: ["install", "--path", productPath.path, "--udid", configuration.udid]))
        }
        launchChildren()
        try await waitForHealthy()
    }

    private func launchChildren() {
        let launch = ProcessInvocation(executable: configuration.goIosExecutable,
            arguments: ["runtest",
                        "--bundle-id", configuration.appBundleID,
                        "--test-runner-bundle-id", configuration.testRunnerBundleID,
                        "--xctest-config", configuration.xctestConfig,
                        "--udid", configuration.udid])
        let forward = ProcessInvocation(executable: configuration.goIosExecutable,
            arguments: ["forward", String(configuration.localPort), String(PhoneRunnerProtocol.port),
                        "--udid", configuration.udid])
        childFailure = nil
        childTasks = [launch, forward].map { invocation in
            Task { [processes] in
                do {
                    let result = try await processes.run(invocation)
                    if !Task.isCancelled { self.childFailure = "\(invocation.arguments[0]) exited \(result.exitCode): \(result.stderr)" }
                } catch {
                    if !Task.isCancelled { self.childFailure = error.localizedDescription }
                }
            }
        }
    }

    private func teardownChildren() async {
        let tasks = childTasks
        childTasks = []
        for task in tasks { task.cancel() }
        for task in tasks { await task.value }
    }

    private func waitForHealthy() async throws {
        var lastError = "no health response"
        for _ in 0..<max(1, configuration.healthCheckAttempts) {
            try Task.checkCancellation()
            if let childFailure {
                throw RunnerSupervisorError.healthChecksExhausted(attempts: 0, lastError: childFailure)
            }
            do {
                try await checkHealth()
                return
            } catch {
                lastError = describe(error)
            }
            try await configuration.sleep(configuration.healthPollInterval)
        }
        throw RunnerSupervisorError.healthChecksExhausted(attempts: configuration.healthCheckAttempts,
                                                          lastError: lastError)
    }

    private func monitorHealth() async throws {
        while true {
            try Task.checkCancellation()
            try await configuration.sleep(configuration.healthPollInterval)
            if let childFailure {
                throw RunnerSupervisorError.healthChecksExhausted(attempts: 0, lastError: childFailure)
            }
            try await checkHealth()
        }
    }

    private func checkHealth() async throws {
        let health = try await client.health()
        guard health.status == "ok", health.version == PhoneRunnerProtocol.version else {
            throw RunnerSupervisorError.healthChecksExhausted(attempts: 1,
                lastError: "Runner version mismatch. Rebuild and install the current runner.")
        }
    }

    private func emit(_ state: RunnerState) {
        continuation.yield(state)
    }

    private func describe(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}

/// Serialize image auto commands because they share the downloaded image cache.
private actor RunnerImageMountQueue {
    static let shared = RunnerImageMountQueue()
    private var tail: Task<Void, Never>?

    func mount(processes: ProcessRunning, invocation: ProcessInvocation) async throws {
        let previous = tail
        let task = Task {
            await previous?.value
            try Task.checkCancellation()
            try await processes.runChecked(invocation)
        }
        tail = Task { _ = try? await task.value }
        try await withTaskCancellationHandler {
            _ = try await task.value
        } onCancel: {
            task.cancel()
        }
    }
}
