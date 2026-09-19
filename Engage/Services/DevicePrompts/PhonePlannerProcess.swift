import Darwin
import Foundation

struct PhonePlannerProcessResult: Sendable {
    let stdout: Data
    let stderr: Data
    let exitCode: Int32
}

enum PhonePlannerProcessError: LocalizedError, Sendable {
    case invalidConfiguration(String)
    case launchFailed(String)
    case timedOut
    case outputLimitExceeded(Int)
    case pipeFailed(Int32)

    var errorDescription: String? {
        switch self {
        case .invalidConfiguration(let message): message
        case .launchFailed(let message): "Could not start the phone planner: \(message)"
        case .timedOut: "The phone planner took too long to respond."
        case .outputLimitExceeded(let limit): "The phone planner exceeded its \(limit)-byte output limit."
        case .pipeFailed(let code): "Could not communicate with the phone planner (system error \(code))."
        }
    }
}

/// Executes an argument vector directly. Output stays in memory and is never
/// logged; the shared byte budget includes both stdout and stderr.
enum PhonePlannerProcess {
    nonisolated static func run(
        executable: URL,
        arguments: [String],
        directory: URL,
        input: Data? = nil,
        environment: [String: String]? = nil,
        timeout: TimeInterval = 60,
        maximumOutputBytes: Int = 1_000_000
    ) async throws -> PhonePlannerProcessResult {
        try Task.checkCancellation()
        guard executable.isFileURL, directory.isFileURL,
              timeout.isFinite, timeout > 0, timeout < Double(Int.max) / 1_000_000_000,
              maximumOutputBytes >= 0 else {
            throw PhonePlannerProcessError.invalidConfiguration("The phone planner requires file URLs, a positive finite timeout, and a nonnegative output limit.")
        }
        guard !arguments.contains(where: { $0.utf8.contains(0) }),
              environment?.allSatisfy({ key, value in
                  !key.isEmpty && !key.contains("=") && !key.utf8.contains(0) && !value.utf8.contains(0)
              }) ?? true else {
            throw PhonePlannerProcessError.invalidConfiguration("The phone planner arguments or environment contain an invalid value.")
        }
        let runner = PhonePlannerProcessRunner(executable: executable, arguments: arguments,
            directory: directory, input: input ?? Data(), environment: environment,
            timeout: timeout, maximumOutputBytes: maximumOutputBytes)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                runner.start(continuation)
            }
        } onCancel: {
            runner.cancel()
        }
    }
}

/// All mutable state and all pipe I/O are confined to `queue`. Dispatch handlers
/// only transfer immutable values into that queue; hence unchecked Sendable.
private final class PhonePlannerProcessRunner: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.joeblau.engage.phone-planner-process", qos: .userInitiated)
    private let process = Process()
    private let outputPipe = Pipe()
    private let errorPipe = Pipe()
    private let inputPipe = Pipe()
    private let input: Data
    private let timeout: TimeInterval
    private let maximumOutputBytes: Int
    private var continuation: CheckedContinuation<PhonePlannerProcessResult, Error>?
    private var outputSource: DispatchSourceRead?
    private var errorSource: DispatchSourceRead?
    private var inputSource: DispatchSourceWrite?
    private var timeoutSource: DispatchSourceTimer?
    private var killSource: DispatchSourceTimer?
    private var output = Data()
    private var errors = Data()
    private var inputOffset = 0
    private var outputClosed = false
    private var errorClosed = false
    private var inputClosed = false
    private var launched = false
    private var exitCode: Int32?
    private var failure: Error?
    private var finished = false

    init(executable: URL, arguments: [String], directory: URL, input: Data,
         environment: [String: String]?, timeout: TimeInterval, maximumOutputBytes: Int) {
        self.input = input
        self.timeout = timeout
        self.maximumOutputBytes = maximumOutputBytes
        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = directory
        process.environment = environment
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        process.standardInput = inputPipe
    }

    func start(_ continuation: CheckedContinuation<PhonePlannerProcessResult, Error>) {
        queue.async { [self] in
            self.continuation = continuation
            if let failure { finish(.failure(failure)); return }
            do {
                try makeNonblocking(outputPipe.fileHandleForReading.fileDescriptor)
                try makeNonblocking(errorPipe.fileHandleForReading.fileDescriptor)
                try makeNonblocking(inputPipe.fileHandleForWriting.fileDescriptor)
                // A planner may exit before consuming its stdin. Never let an
                // EPIPE write deliver SIGPIPE to the Engage application itself.
                guard fcntl(inputPipe.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1) != -1 else {
                    throw PhonePlannerProcessError.pipeFailed(errno)
                }
                process.terminationHandler = { [weak self] process in
                    let status = process.terminationStatus
                    self?.queue.async { [weak self] in
                        guard let self, !self.finished else { return }
                        self.exitCode = status
                        self.closeInput()
                        self.completeIfReady()
                    }
                }
                try process.run()
                launched = true
                // Only the child needs these ends. Closing our copies allows
                // readers to observe EOF when the child exits.
                try? outputPipe.fileHandleForWriting.close()
                try? errorPipe.fileHandleForWriting.close()
                try? inputPipe.fileHandleForReading.close()
                installReaders()
                installWriter()
                let timer = DispatchSource.makeTimerSource(queue: queue)
                timer.schedule(deadline: .now() + timeout)
                timer.setEventHandler { [weak self] in self?.beginFailure(PhonePlannerProcessError.timedOut) }
                timeoutSource = timer
                timer.resume()
            } catch {
                beginFailure(PhonePlannerProcessError.launchFailed(error.localizedDescription))
            }
        }
    }

    func cancel() {
        queue.async { [self] in beginFailure(CancellationError()) }
    }

    private func makeNonblocking(_ descriptor: Int32) throws {
        let flags = fcntl(descriptor, F_GETFL)
        guard flags != -1, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) != -1 else {
            throw PhonePlannerProcessError.pipeFailed(errno)
        }
    }

    private func installReaders() {
        let stdout = DispatchSource.makeReadSource(fileDescriptor: outputPipe.fileHandleForReading.fileDescriptor, queue: queue)
        stdout.setEventHandler { [weak self] in self?.read(isError: false) }
        stdout.setCancelHandler { [handle = outputPipe.fileHandleForReading] in try? handle.close() }
        outputSource = stdout
        stdout.resume()
        let stderr = DispatchSource.makeReadSource(fileDescriptor: errorPipe.fileHandleForReading.fileDescriptor, queue: queue)
        stderr.setEventHandler { [weak self] in self?.read(isError: true) }
        stderr.setCancelHandler { [handle = errorPipe.fileHandleForReading] in try? handle.close() }
        errorSource = stderr
        stderr.resume()
    }

    private func installWriter() {
        guard !input.isEmpty else { closeInput(); return }
        let writer = DispatchSource.makeWriteSource(fileDescriptor: inputPipe.fileHandleForWriting.fileDescriptor, queue: queue)
        writer.setEventHandler { [weak self] in self?.writeInput() }
        writer.setCancelHandler { [handle = inputPipe.fileHandleForWriting] in try? handle.close() }
        inputSource = writer
        writer.resume()
    }

    private func read(isError: Bool) {
        guard !finished, failure == nil, !(isError ? errorClosed : outputClosed) else { return }
        let descriptor = (isError ? errorPipe : outputPipe).fileHandleForReading.fileDescriptor
        var buffer = [UInt8](repeating: 0, count: 16_384)
        // Bound each callback so a continuously writing process cannot starve
        // cancellation, timeout, stderr, or stdin work on the same queue.
        for _ in 0..<16 {
            let count = buffer.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress!, $0.count) }
            if count > 0 {
                let remaining = maximumOutputBytes - output.count - errors.count
                guard count <= remaining else {
                    beginFailure(PhonePlannerProcessError.outputLimitExceeded(maximumOutputBytes))
                    return
                }
                if isError { errors.append(contentsOf: buffer.prefix(count)) }
                else { output.append(contentsOf: buffer.prefix(count)) }
            } else if count == 0 {
                closeReader(isError: isError)
                completeIfReady()
                return
            } else {
                let code = errno
                if code == EAGAIN || code == EWOULDBLOCK { return }
                if code == EINTR { continue }
                beginFailure(PhonePlannerProcessError.pipeFailed(code))
                return
            }
        }
    }

    private func writeInput() {
        guard !finished, failure == nil, !inputClosed else { return }
        let descriptor = inputPipe.fileHandleForWriting.fileDescriptor
        for _ in 0..<16 {
            guard inputOffset < input.count else { closeInput(); return }
            let offset = inputOffset
            let count = input.withUnsafeBytes { buffer in
                Darwin.write(descriptor, buffer.baseAddress!.advanced(by: offset), min(16_384, buffer.count - offset))
            }
            if count > 0 { inputOffset += count }
            else if count == 0 { return }
            else {
                let code = errno
                if code == EAGAIN || code == EWOULDBLOCK { return }
                if code == EINTR { continue }
                // Early exit can legitimately close stdin while producing a
                // useful error response. Preserve that response and exit code.
                if code == EPIPE { closeInput(); return }
                beginFailure(PhonePlannerProcessError.pipeFailed(code))
                return
            }
        }
        if inputOffset == input.count { closeInput() }
    }

    private func closeReader(isError: Bool) {
        if isError {
            guard !errorClosed else { return }
            errorClosed = true
            if let source = errorSource { source.cancel(); errorSource = nil }
            else { try? errorPipe.fileHandleForReading.close() }
        } else {
            guard !outputClosed else { return }
            outputClosed = true
            if let source = outputSource { source.cancel(); outputSource = nil }
            else { try? outputPipe.fileHandleForReading.close() }
        }
    }

    private func closeInput() {
        guard !inputClosed else { return }
        inputClosed = true
        if let source = inputSource { source.cancel(); inputSource = nil }
        else { try? inputPipe.fileHandleForWriting.close() }
    }

    private func beginFailure(_ error: Error) {
        guard !finished, failure == nil else { return }
        failure = error
        timeoutSource?.cancel()
        timeoutSource = nil
        closeInput()
        closeReader(isError: false)
        closeReader(isError: true)
        guard launched, process.isRunning else { finish(.failure(error)); return }
        process.terminate()
        // SIGTERM is cooperative. Escalate after a short grace period so an
        // unresponsive planner cannot keep a cancelled request alive.
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + .milliseconds(250))
        timer.setEventHandler { [weak self] in
            guard let self, !self.finished else { return }
            if self.process.isRunning { _ = Darwin.kill(self.process.processIdentifier, SIGKILL) }
            self.finish(.failure(error))
        }
        killSource = timer
        timer.resume()
    }

    private func completeIfReady() {
        guard !finished, let exitCode else { return }
        if let failure { finish(.failure(failure)) }
        else if outputClosed && errorClosed {
            finish(.success(.init(stdout: output, stderr: errors, exitCode: exitCode)))
        }
    }

    private func finish(_ result: Result<PhonePlannerProcessResult, Error>) {
        guard !finished, let continuation else { return }
        finished = true
        self.continuation = nil
        process.terminationHandler = nil
        timeoutSource?.cancel()
        timeoutSource = nil
        killSource?.cancel()
        killSource = nil
        closeInput()
        closeReader(isError: false)
        closeReader(isError: true)
        try? outputPipe.fileHandleForWriting.close()
        try? errorPipe.fileHandleForWriting.close()
        try? inputPipe.fileHandleForReading.close()
        continuation.resume(with: result)
    }
}
