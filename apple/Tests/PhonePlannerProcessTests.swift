import Darwin
import Foundation

@main
enum PhonePlannerProcessTests {
    static func main() async throws {
        if CommandLine.arguments.count > 1, CommandLine.arguments[1].hasPrefix("--child-") {
            try childMode()
            return
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("shortreel-process-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let binary = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL

        let literal = "spaces; $(unexecuted) `unexecuted` \"quotes\""
        let basic = try await PhonePlannerProcess.run(executable: binary,
            arguments: ["--child-basic", literal], directory: root,
            input: Data([0, 255, 10, 128, 1]), environment: ["SHORTREEL_PROCESS_TEST_VALUE": "inherited exactly"])
        expect(basic.exitCode == 7, "nonzero exit status must be returned")
        expect(basic.stdout == Data([0, 255, 10, 128, 1]), "stdin must preserve arbitrary binary bytes")
        let basicDetails = try JSONDecoder().decode([String: String].self, from: basic.stderr)
        expect(basicDetails["argument"] == literal, "arguments must be passed literally without a shell")
        expect(basicDetails["environment"] == "inherited exactly", "explicit environment must reach the child")
        expect(basicDetails["directory"] == root.resolvingSymlinksInPath().path, "working directory must reach the child")

        let pressure = try await PhonePlannerProcess.run(executable: binary,
            arguments: ["--child-pressure"], directory: root, timeout: 5, maximumOutputBytes: 2_097_152)
        expect(pressure.stdout == Data(repeating: 79, count: 1_048_576), "stdout must drain past pipe capacity")
        expect(pressure.stderr == Data(repeating: 69, count: 1_048_576), "stderr must drain concurrently with stdout")

        let duplexInput = Data((0..<2_097_152).map { UInt8($0 % 256) })
        let duplex = try await PhonePlannerProcess.run(executable: binary,
            arguments: ["--child-duplex"], directory: root, input: duplexInput,
            timeout: 5, maximumOutputBytes: 3_000_000)
        expect(duplex.stdout == Data(repeating: 65, count: 262_144) + duplexInput,
               "large stdin must progress while both output pipes are drained")
        expect(duplex.stderr == Data(repeating: 66, count: 262_144), "duplex stderr is preserved")

        let early = try await PhonePlannerProcess.run(executable: binary,
            arguments: ["--child-early-exit"], directory: root, input: Data(repeating: 42, count: 8_388_608),
            timeout: 3, maximumOutputBytes: 1024)
        expect(early.exitCode == 9 && early.stderr == Data("declined input".utf8),
               "closed child stdin must not crash ShortReel or hide the child's error")

        let cancelledPID = root.appendingPathComponent("cancelled.pid")
        let cancelled = Task {
            try await PhonePlannerProcess.run(executable: binary,
                arguments: ["--child-wait", cancelledPID.path], directory: root,
                input: Data(repeating: 42, count: 8_388_608), timeout: 10)
        }
        let pid = try await waitForPID(at: cancelledPID)
        let cancellationStart = Date()
        cancelled.cancel()
        do {
            _ = try await cancelled.value
            fatalError("Task cancellation must throw")
        } catch is CancellationError { }
        expect(Date().timeIntervalSince(cancellationStart) < 2, "cancellation must be prompt even with blocked stdin")
        try await expectExited(pid)

        let timeoutPID = root.appendingPathComponent("timeout.pid")
        let timeoutStart = Date()
        do {
            _ = try await PhonePlannerProcess.run(executable: binary,
                arguments: ["--child-wait", timeoutPID.path], directory: root,
                timeout: 0.3)
            fatalError("A blocked process must time out")
        } catch PhonePlannerProcessError.timedOut { }
        expect(Date().timeIntervalSince(timeoutStart) < 2, "timeout must escalate when SIGTERM is ignored")
        try await expectExited(try await waitForPID(at: timeoutPID))

        do {
            _ = try await PhonePlannerProcess.run(executable: binary,
                arguments: ["--child-combined-cap"], directory: root,
                timeout: 2, maximumOutputBytes: 1000)
            fatalError("The cap must cover stdout plus stderr together")
        } catch PhonePlannerProcessError.outputLimitExceeded(let limit) {
            expect(limit == 1000, "reported output cap must match configuration")
        }

        let overflowingPID = root.appendingPathComponent("overflow.pid")
        do {
            _ = try await PhonePlannerProcess.run(executable: binary,
                arguments: ["--child-overflow", overflowingPID.path], directory: root,
                timeout: 3, maximumOutputBytes: 2048)
            fatalError("Continuous output must be terminated at the cap")
        } catch PhonePlannerProcessError.outputLimitExceeded { }
        try await expectExited(try await waitForPID(at: overflowingPID))

        for _ in 0..<30 {
            let task = Task {
                try await PhonePlannerProcess.run(executable: binary,
                    arguments: ["--child-empty"], directory: root, timeout: 1)
            }
            task.cancel()
            do {
                _ = try await task.value
                fatalError("Already-cancelled tasks must not start a subprocess")
            } catch is CancellationError { }
        }

        do {
            _ = try await PhonePlannerProcess.run(executable: root.appendingPathComponent("missing"),
                arguments: [], directory: root)
            fatalError("Missing executable must fail")
        } catch PhonePlannerProcessError.launchFailed { }
        print("Phone planner process tests passed")
    }

    private static func childMode() throws {
        switch CommandLine.arguments[1] {
        case "--child-basic":
            let bytes = FileHandle.standardInput.readDataToEndOfFile()
            writeAll(bytes, descriptor: STDOUT_FILENO)
            let metadata = ["argument": CommandLine.arguments[2],
                "environment": ProcessInfo.processInfo.environment["SHORTREEL_PROCESS_TEST_VALUE"] ?? "",
                "directory": URL(fileURLWithPath: FileManager.default.currentDirectoryPath).resolvingSymlinksInPath().path]
            writeAll(try JSONEncoder().encode(metadata), descriptor: STDERR_FILENO)
            exit(7)
        case "--child-pressure":
            for _ in 0..<8 {
                writeAll(Data(repeating: 79, count: 131_072), descriptor: STDOUT_FILENO)
                writeAll(Data(repeating: 69, count: 131_072), descriptor: STDERR_FILENO)
            }
        case "--child-duplex":
            writeAll(Data(repeating: 65, count: 262_144), descriptor: STDOUT_FILENO)
            writeAll(Data(repeating: 66, count: 262_144), descriptor: STDERR_FILENO)
            writeAll(FileHandle.standardInput.readDataToEndOfFile(), descriptor: STDOUT_FILENO)
        case "--child-early-exit":
            writeAll(Data("declined input".utf8), descriptor: STDERR_FILENO)
            exit(9)
        case "--child-wait", "--child-overflow":
            signal(SIGTERM, SIG_IGN)
            signal(SIGPIPE, SIG_IGN)
            try String(getpid()).write(toFile: CommandLine.arguments[2], atomically: true, encoding: .utf8)
            if CommandLine.arguments[1] == "--child-overflow" {
                writeAll(Data(repeating: 65, count: 65_536), descriptor: STDOUT_FILENO)
            }
            while true { pause() }
        case "--child-combined-cap":
            writeAll(Data(repeating: 65, count: 600), descriptor: STDOUT_FILENO)
            writeAll(Data(repeating: 66, count: 600), descriptor: STDERR_FILENO)
        case "--child-empty": break
        default: fatalError("Unknown child mode")
        }
    }

    private static func writeAll(_ data: Data, descriptor: Int32) {
        var offset = 0
        while offset < data.count {
            let count = data.withUnsafeBytes { Darwin.write(descriptor, $0.baseAddress!.advanced(by: offset), $0.count - offset) }
            if count > 0 { offset += count }
            else if count < 0 && errno == EINTR { continue }
            else { return }
        }
    }

    private static func waitForPID(at path: URL) async throws -> Int32 {
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            if let text = try? String(contentsOf: path, encoding: .utf8), let pid = Int32(text) { return pid }
            try await Task.sleep(for: .milliseconds(10))
        }
        fatalError("Test child did not become ready")
    }

    private static func expectExited(_ pid: Int32) async throws {
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline {
            if Darwin.kill(pid, 0) == -1 && errno == ESRCH { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        fatalError("Cancelled, timed-out, or overflowing child is still alive")
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() { fatalError(message) }
    }
}
