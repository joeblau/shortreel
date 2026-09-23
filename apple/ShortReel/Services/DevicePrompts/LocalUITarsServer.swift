import Foundation

@MainActor @Observable
final class LocalUITarsServer {
    static let shared = LocalUITarsServer()

    static let modelReference = "adriabama06/UI-TARS-1.5-7B-GGUF:Q4_K_M"
    static let port = 11435
    static let baseURL = URL(string: "http://127.0.0.1:\(port)")!
    static let contextLength = 16_384

    enum State: Equatable, Sendable {
        case idle
        case starting(since: Date)
        case ready
        case failed(String)
    }

    private(set) var state: State = .idle
    @ObservationIgnored private var process: Process?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var stderrTail: [String] = []

    var configuration: UITarsPhonePlanner.Configuration {
        .init(baseURL: Self.baseURL.appendingPathComponent("v1").absoluteString,
              apiKey: "local", model: "ui-tars-1.5-7b")
    }

    var unavailabilityReason: String? {
        switch state {
        case .ready:
            return nil
        case .idle:
            return "Starting the local UI-TARS model…"
        case .starting(let since):
            let minutes = Int(Date().timeIntervalSince(since) / 60)
            return minutes >= 1
                ? "Preparing the local UI-TARS model (\(minutes) min so far; the first run downloads about 5 GB)…"
                : "Preparing the local UI-TARS model (the first run downloads about 5 GB)…"
        case .failed(let reason):
            return reason
        }
    }

    func ensureRunning() {
        guard task == nil else { return }
        if case .ready = state { return }
        task = Task { [weak self] in
            await self?.start()
            self?.task = nil
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        if let process, process.isRunning { process.terminate() }
        process = nil
        state = .idle
    }

    private func start() async {
        state = .starting(since: .now)
        if await Self.health() == .ready { state = .ready; return }
        guard let executable = Self.executableURL else {
            state = .failed("llama.cpp is not installed. Run `SHORTREEL_INSTALL_UITARS=1 bun shortreel` to install it with Homebrew, then try again.")
            return
        }
        if process == nil || process?.isRunning == false {
            do { try launch(executable) }
            catch {
                state = .failed("Couldn’t start the local UI-TARS model: \(error.localizedDescription)")
                return
            }
        }
        let deadline = ContinuousClock.now + .seconds(45 * 60)
        while ContinuousClock.now < deadline {
            if Task.isCancelled { return }
            if let process, !process.isRunning {
                let detail = stderrTail.suffix(3).joined(separator: " ")
                state = .failed("The local UI-TARS model stopped unexpectedly. \(detail)")
                self.process = nil
                return
            }
            if await Self.health() == .ready { state = .ready; return }
            try? await Task.sleep(for: .seconds(1))
        }
        state = .failed("The local UI-TARS model did not become ready. Check your network connection and try again.")
    }

    private func launch(_ executable: URL) throws {
        let process = Process()
        process.executableURL = executable
        process.arguments = [
            "-hf", Self.modelReference,
            "--host", "127.0.0.1", "--port", String(Self.port),
            "-c", String(Self.contextLength), "--temp", "0",
            "--no-webui",
        ]
        let inherited = ["HOME", "USER", "TMPDIR", "PATH", "HTTP_PROXY", "HTTPS_PROXY", "NO_PROXY", "SSL_CERT_FILE"]
        process.environment = ProcessInfo.processInfo.environment.filter { inherited.contains($0.key) }
        process.standardOutput = FileHandle.nullDevice
        let stderr = Pipe()
        process.standardError = stderr
        stderrTail = []
        stderr.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let text = String(decoding: handle.availableData, as: UTF8.self)
            let lines = text.split(whereSeparator: \.isNewline).map(String.init).suffix(5)
            guard !lines.isEmpty else { return }
            Task { @MainActor [weak self] in
                self?.stderrTail = Array((self?.stderrTail ?? []).suffix(5) + lines)
            }
        }
        try process.run()
        self.process = process
    }

    private static var executableURL: URL? {
        ["/opt/homebrew/bin/llama-server", "/usr/local/bin/llama-server"]
            .map(URL.init(fileURLWithPath:))
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    private enum Health { case ready, loading, unreachable }

    private static func health() async -> Health {
        var request = URLRequest(url: baseURL.appendingPathComponent("health"))
        request.timeoutInterval = 2
        guard let (_, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse else { return .unreachable }
        return http.statusCode == 200 ? .ready : .loading
    }

    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 3
        return URLSession(configuration: config)
    }()
}
