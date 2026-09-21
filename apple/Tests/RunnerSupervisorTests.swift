import Foundation

// swiftc -swift-version 6 PhoneRunnerShared/PhoneRunnerProtocol.swift ShortReel/Services/PhoneRunner/RunnerClient.swift ShortReel/Services/PhoneRunner/RunnerSupervisor.swift ShortReel/Services/PhoneRunner/RunnerProvisioning.swift Tests/RunnerSupervisorTests.swift -o /tmp/sr-supervisor-tests
@main
enum RunnerSupervisorTests {
    private static let udid = "00008110-00123456789ABCDE"
    private static let productPath = URL(fileURLWithPath: "/tmp/build/ShortReelRunner.app")
    private static let sampleIdentities = """
             1) 4A5C0D2B7F0A1B2C3D4E5F6A7B8C9D0E1F2A3B4C "Apple Development: Joe Blau (ABCDE12345)"
             2) 5B6D1E3C8A1B2C3D4E5F6A7B8C9D0E1F2A3B4C5D "Apple Distribution: Joe Blau (ABCDE12345)"
             3) 6C7E2F4D9B1C2D3E4F5A6B7C8D9E0F1A2B3C4D5E "Apple Development: joe@example.com (FGHIJ67890)"
             3 valid identities found
        """

    static func main() async {
        await testSystemProcessRunner()
        await testProcessCancellation()
        await testVersionMismatch()
        await testHappyPath()
        await testRestartOnHealthFailure()
        await testExhaustedAttempts()
        await testProvisioningParsing()
        await testProvisioningStatusAndProducts()
        print("Runner supervisor tests passed")
    }

    private static func testSystemProcessRunner() async {
        let runner = SystemProcessRunner()
        do {
            let echo = try await runner.run(ProcessInvocation(executable: "echo", arguments: ["hello runner"]))
            expect(echo.exitCode == 0 && echo.stdout == "hello runner\n", "SystemProcessRunner captures stdout and exit 0")
            let failure = try await runner.run(ProcessInvocation(executable: "/usr/bin/false", arguments: []))
            expect(failure.exitCode == 1, "SystemProcessRunner reports non-zero exits without throwing")
        } catch {
            expect(false, "SystemProcessRunner threw unexpectedly: \(error)")
        }
    }

    private static func testProcessCancellation() async {
        let runner = SystemProcessRunner()
        for delay in [0, 30] {
            let task = Task { try await runner.run(.init(executable: "/bin/sleep", arguments: ["30"])) }
            try? await Task.sleep(for: .milliseconds(delay))
            let start = ContinuousClock.now
            task.cancel()
            do {
                _ = try await task.value
                expect(false, "cancelled process must throw")
            } catch is CancellationError { } catch { expect(false, "unexpected cancellation error: \(error)") }
            expect(ContinuousClock.now - start < .seconds(3), "cancelled process must exit promptly")
        }
    }

    private static func testVersionMismatch() async {
        let processes = FakeProcessRunner()
        await processes.setBehavior(.hang, forCommandPrefix: ["runtest"])
        await processes.setBehavior(.hang, forCommandPrefix: ["forward"])
        let client = FakeRunnerClient()
        for _ in 0..<3 {
            await client.scriptHealth(.success(.init(status: "ok", version: 0, deviceModel: "iPhone", osVersion: "27")))
        }
        let supervisor = makeSupervisor(processes: processes, tunnel: FakeTunnel(), client: client) { $0.maxAttempts = 1 }
        await supervisor.start()
        var states: [RunnerState] = []
        for await state in supervisor.states { states.append(state) }
        guard case .failed(let reason) = states.last else { preconditionFailure("old runner must not become ready") }
        expect(reason.contains("version mismatch"), "old runner gets an actionable error")
        await supervisor.stop()
    }

    private static func testHappyPath() async {
        let processes = FakeProcessRunner()
        await processes.setBehavior(.hang, forCommandPrefix: ["runtest"])
        await processes.setBehavior(.hang, forCommandPrefix: ["forward"])
        let tunnel = FakeTunnel()
        let client = FakeRunnerClient()
        let supervisor = makeSupervisor(processes: processes, tunnel: tunnel, client: client)
        let log = StateLog()
        let collector = Task { for await state in supervisor.states { await log.append(state) }; await log.markFinished() }
        await supervisor.start()

        expect(await log.waitForCount(2), "happy path should emit starting then ready")
        let states = await log.states
        expect(states == [.starting, .ready(localPort: PhoneRunnerProtocol.port)],
               "happy path state sequence, got \(states)")
        expect(await tunnel.ensureCalls == 1, "tunnel ensured exactly once")
        let invocations = await processes.invocations
        expect(invocations.contains(ProcessInvocation(executable: "ios",
            arguments: ["image", "auto", "--basedir", FileManager.default.temporaryDirectory.appending(path: "shortreel-test-images").path, "--udid", udid])), "image auto runs for the UDID")
        expect(invocations.contains(ProcessInvocation(executable: "ios",
            arguments: ["install", "--path", productPath.path, "--udid", udid])), "runner product is installed")
        expect(invocations.contains(ProcessInvocation(executable: "ios",
            arguments: ["install", "--path", "/tmp/build/ShortReelRunnerUITests-Runner.app", "--udid", udid])), "UI test host is installed as well")
        expect(invocations.contains(ProcessInvocation(executable: "ios",
            arguments: ["runtest", "--bundle-id", "com.joeblau.shortreel.runner",
                        "--test-runner-bundle-id", "com.joeblau.shortreel.runner.uitests.xctrunner",
                        "--xctest-config", "ShortReelRunnerUITests.xctest",
                        "--udid", udid])), "runtest launches the UITests bundle")
        expect(invocations.contains(ProcessInvocation(executable: "ios",
            arguments: ["forward", "8700", "8700", "--udid", udid])), "the runner port is forwarded")
        let healthCalls = await client.healthCalls
        expect(healthCalls >= 1, "ready requires at least one health check")

        await supervisor.stop()
        expect(await log.waitForFinish(), "state stream finishes after stop")
        collector.cancel()
    }

    private static func testRestartOnHealthFailure() async {
        let processes = FakeProcessRunner()
        await processes.setBehavior(.hang, forCommandPrefix: ["runtest"])
        await processes.setBehavior(.hang, forCommandPrefix: ["forward"])
        let tunnel = FakeTunnel()
        let client = FakeRunnerClient()
        await client.scriptHealth(.success(Self.health))
        await client.scriptHealth(.failure(FakeError.unhealthy))
        await client.scriptHealth(.success(Self.health))
        let supervisor = makeSupervisor(processes: processes, tunnel: tunnel, client: client)
        let log = StateLog()
        let collector = Task { for await state in supervisor.states { await log.append(state) }; await log.markFinished() }
        await supervisor.start()

        expect(await log.waitForCount(4), "restart path should emit four states")
        let states = await log.states
        expect(states == [.starting, .ready(localPort: PhoneRunnerProtocol.port),
                          .restarting(attempt: 1), .ready(localPort: PhoneRunnerProtocol.port)],
               "restart state sequence, got \(states)")
        expect(await processes.count(prefix: "runtest") == 2, "runtest relaunched after health failure")
        expect(await processes.count(prefix: "forward") == 2, "forward re-established after health failure")
        expect(await tunnel.ensureCalls == 2, "tunnel re-ensured on restart")

        await supervisor.stop()
        expect(await log.waitForFinish(), "state stream finishes after stop")
        collector.cancel()
    }

    private static func testExhaustedAttempts() async {
        let processes = FakeProcessRunner()
        await processes.setBehavior(.result(ProcessResult(stdout: "", stderr: "mount failed", exitCode: 1)),
                                    forCommandPrefix: ["image"])
        let tunnel = FakeTunnel()
        let client = FakeRunnerClient()
        let supervisor = makeSupervisor(processes: processes, tunnel: tunnel, client: client) {
            $0.maxAttempts = 3
        }
        let log = StateLog()
        let collector = Task { for await state in supervisor.states { await log.append(state) }; await log.markFinished() }
        await supervisor.start()

        expect(await log.waitForCount(4), "exhaustion path should emit four states")
        let states = await log.states
        expect(states.prefix(3) == [.starting, .restarting(attempt: 1), .restarting(attempt: 2)],
               "backoff attempts surface as restarting, got \(states)")
        guard states.count == 4, case .failed(let reason) = states[3] else {
            expect(false, "expected terminal .failed, got \(states)")
            return
        }
        expect(reason.contains("mount failed"), "failure reason carries the command stderr, got \(reason)")
        expect(await processes.count(prefix: "image") == 3, "image auto retried up to maxAttempts")
        expect(await processes.count(prefix: "runtest") == 0, "runtest never launches when bring-up fails")
        expect(await log.waitForFinish(), "state stream finishes after permanent failure")
        collector.cancel()
    }

    private static func testProvisioningParsing() async {
        let identities = RunnerProvisioning.parseSigningIdentities(sampleIdentities)
        expect(identities == [
            RunnerSigningIdentity(sha1: "4A5C0D2B7F0A1B2C3D4E5F6A7B8C9D0E1F2A3B4C", name: "Apple Development: Joe Blau (ABCDE12345)"),
            RunnerSigningIdentity(sha1: "5B6D1E3C8A1B2C3D4E5F6A7B8C9D0E1F2A3B4C5D", name: "Apple Distribution: Joe Blau (ABCDE12345)"),
            RunnerSigningIdentity(sha1: "6C7E2F4D9B1C2D3E4F5A6B7C8D9E0F1A2B3C4D5E", name: "Apple Development: joe@example.com (FGHIJ67890)"),
        ], "find-identity output parses into identities, got \(identities)")
        expect(RunnerProvisioning.parseSigningIdentities("     0 valid identities found\n").isEmpty,
               "empty find-identity output parses to zero identities")
        expect(RunnerProvisioning.parseSigningIdentities("").isEmpty, "blank output parses to zero identities")
    }

    private static func testProvisioningStatusAndProducts() async {
        let root = FileManager.default.temporaryDirectory.appending(path: "sr-provisioning-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let products = root.appending(path: "Build/Products/Debug-iphoneos", directoryHint: .isDirectory)

        let processes = FakeProcessRunner()
        await processes.setBehavior(.result(ProcessResult(stdout: "1.3.0\n", stderr: "", exitCode: 0)),
                                    forCommandPrefix: ["version"])
        await processes.setBehavior(.result(ProcessResult(stdout: sampleIdentities, stderr: "", exitCode: 0)),
                                    forCommandPrefix: ["find-identity"])
        let provisioning = RunnerProvisioning(processes: processes)

        do {
            let identity = try await provisioning.appleDevelopmentIdentity()
            expect(identity.name == "Apple Development: Joe Blau (ABCDE12345)",
                   "the first Apple Development identity wins, got \(identity)")
        } catch {
            expect(false, "appleDevelopmentIdentity threw unexpectedly: \(error)")
        }

        // Missing products block readiness.
        if case .runnerProductsMissing = await provisioning.status(derivedData: root) {} else {
            expect(false, "status should report missing products before anything is built")
        }
        do {
            _ = try provisioning.locateRunnerProducts(inDerivedData: root)
            expect(false, "locateRunnerProducts should throw when products are absent")
        } catch {
            expect(error.localizedDescription.contains("build-for-testing"),
                   "product error is actionable, got \(error.localizedDescription)")
        }

        // Once both bundles exist, status is ready.
        do {
            try FileManager.default.createDirectory(at: products.appending(path: "ShortReelRunner.app"), withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: products.appending(path: "ShortReelRunnerUITests-Runner.app"), withIntermediateDirectories: true)
            let found = try provisioning.locateRunnerProducts(inDerivedData: root)
            expect(found.runnerApp.lastPathComponent == "ShortReelRunner.app", "runner app located")
            expect(found.uitestRunnerApp.lastPathComponent == "ShortReelRunnerUITests-Runner.app", "UITests runner app located")
        } catch {
            expect(false, "locateRunnerProducts threw unexpectedly: \(error)")
        }
        if case .ready(let identity, _) = await provisioning.status(derivedData: root) {
            expect(identity.name.hasPrefix("Apple Development:"), "ready carries the signing identity")
        } else {
            expect(false, "status should be ready once go-ios, identity, and products exist")
        }

        // No Apple Development identity is an actionable error, not an opaque failure.
        let distributionOnly = FakeProcessRunner()
        await distributionOnly.setBehavior(.result(ProcessResult(stdout: "1.3.0\n", stderr: "", exitCode: 0)),
                                           forCommandPrefix: ["version"])
        await distributionOnly.setBehavior(.result(ProcessResult(stdout: """
                 1) 5B6D1E3C8A1B2C3D4E5F6A7B8C9D0E1F2A3B4C5D "Apple Distribution: Joe Blau (ABCDE12345)"
                 1 valid identities found
            """, stderr: "", exitCode: 0)), forCommandPrefix: ["find-identity"])
        let unsigned = RunnerProvisioning(processes: distributionOnly)
        do {
            _ = try await unsigned.appleDevelopmentIdentity()
            expect(false, "appleDevelopmentIdentity should throw without a development identity")
        } catch {
            expect(error.localizedDescription.contains("Xcode › Settings › Accounts"),
                   "identity error is actionable, got \(error.localizedDescription)")
        }
        expect(await unsigned.status(derivedData: root) == .noAppleDevelopmentIdentity,
               "status reports the missing identity")

        // go-ios absence surfaces as its own status.
        let noGoIos = FakeProcessRunner()
        await noGoIos.setBehavior(.failure(FakeError.unhealthy), forCommandPrefix: ["version"])
        expect(await RunnerProvisioning(processes: noGoIos).status(derivedData: root) == .goIosNotInstalled,
               "status reports go-ios not installed")

        // sign and install wrap the documented go-ios commands.
        do {
            let signed = try await provisioning.sign(runnerAppAt: productPath,
                                                     p12: URL(fileURLWithPath: "/tmp/dev.p12"),
                                                     profile: URL(fileURLWithPath: "/tmp/dev.mobileprovision"),
                                                     output: URL(fileURLWithPath: "/tmp/signed.app"))
            expect(signed.path == "/tmp/signed.app", "sign returns the output path")
            try await provisioning.install(appAt: productPath, udid: udid)
            let invocations = await processes.invocations
            expect(invocations.contains(ProcessInvocation(executable: "ios",
                arguments: ["sign", "app", "--path", productPath.path,
                            "--p12file", "/tmp/dev.p12", "--profile", "/tmp/dev.mobileprovision",
                            "--output", "/tmp/signed.app"])), "sign wraps ios sign app")
            expect(invocations.contains(ProcessInvocation(executable: "ios",
                arguments: ["install", "--path", productPath.path, "--udid", udid])), "install wraps ios install")
        } catch {
            expect(false, "sign/install threw unexpectedly: \(error)")
        }
    }

    private static let health = HealthResponse(status: "ok", version: PhoneRunnerProtocol.version, deviceModel: "iPhone17,1", osVersion: "26.0")

    private static func makeSupervisor(processes: FakeProcessRunner, tunnel: FakeTunnel, client: FakeRunnerClient,
                                       configure: (inout RunnerSupervisor.Configuration) -> Void = { _ in }) -> RunnerSupervisor {
        var configuration = RunnerSupervisor.Configuration(udid: udid)
        configuration.imageCacheDirectory = FileManager.default.temporaryDirectory.appending(path: "shortreel-test-images")
        configuration.runnerProductPath = productPath
        configuration.uitestRunnerProductPath = URL(fileURLWithPath: "/tmp/build/ShortReelRunnerUITests-Runner.app")
        configuration.healthCheckAttempts = 3
        configuration.healthPollInterval = 0.001
        configuration.backoff = [0.001, 0.001, 0.001, 0.001, 0.001]
        configuration.sleep = { _ in }
        configure(&configuration)
        return RunnerSupervisor(configuration: configuration, processes: processes, tunnel: tunnel, client: client)
    }

    private static func expect(_ condition: Bool, _ message: @autoclosure () -> String) {
        precondition(condition, message())
    }
}

private enum FakeError: Error {
    case unhealthy
}

private actor FakeTunnel: TunnelManaging {
    private(set) var ensureCalls = 0

    func ensureRunning() async throws {
        ensureCalls += 1
    }
}

private actor FakeProcessRunner: ProcessRunning {
    enum Behavior {
        case result(ProcessResult)
        case failure(Error)
        case hang
    }

    private var behaviors: [[String]: Behavior] = [:]
    private(set) var invocations: [ProcessInvocation] = []

    func setBehavior(_ behavior: Behavior, forCommandPrefix prefix: [String]) {
        behaviors[prefix] = behavior
    }

    func count(prefix: String) -> Int {
        invocations.filter { $0.arguments.first == prefix }.count
    }

    func run(_ invocation: ProcessInvocation) async throws -> ProcessResult {
        invocations.append(invocation)
        let behavior = behaviors.first(where: { invocation.arguments.starts(with: $0.key) })?.value
            ?? .result(ProcessResult(stdout: "", stderr: "", exitCode: 0))
        switch behavior {
        case .result(let result): return result
        case .failure(let error): throw error
        case .hang:
            try await Task.sleep(for: .seconds(600))
            throw CancellationError()
        }
    }
}

private actor FakeRunnerClient: PhoneRunnerServing {
    private var scriptedHealth: [Result<HealthResponse, Error>] = []
    private(set) var healthCalls = 0

    func scriptHealth(_ result: Result<HealthResponse, Error>) {
        scriptedHealth.append(result)
    }

    func health() async throws -> HealthResponse {
        healthCalls += 1
        if !scriptedHealth.isEmpty { return try scriptedHealth.removeFirst().get() }
        return HealthResponse(status: "ok", version: PhoneRunnerProtocol.version, deviceModel: "iPhone17,1", osVersion: "26.0")
    }

    func tap(_ request: TapRequest) async throws { throw FakeError.unhealthy }
    func drag(_ request: DragRequest) async throws { throw FakeError.unhealthy }
    func swipe(_ request: SwipeRequest) async throws { throw FakeError.unhealthy }
    func pinch(_ request: PinchRequest) async throws { throw FakeError.unhealthy }
    func type(_ request: TypeRequest) async throws { throw FakeError.unhealthy }
    func pressKey(_ request: KeyRequest) async throws { }
    func pressButton(_ request: PressButtonRequest) async throws { throw FakeError.unhealthy }
    func openApp(_ request: OpenAppRequest) async throws { throw FakeError.unhealthy }
    func performAlertAction(_ request: AlertActionRequest) async throws { throw FakeError.unhealthy }
    func appState(target: RunnerTarget) async throws -> AppStateResponse { throw FakeError.unhealthy }
    func tree(target: RunnerTarget, maxDepth: Int?) async throws -> TreeResponse { throw FakeError.unhealthy }
    func alerts(target: RunnerTarget) async throws -> AlertsResponse { throw FakeError.unhealthy }
    func locked() async throws -> LockedResponse { throw FakeError.unhealthy }
    func screenshot() async throws -> Data { throw FakeError.unhealthy }
}

private actor StateLog {
    private(set) var states: [RunnerState] = []
    private(set) var finished = false

    func append(_ state: RunnerState) {
        states.append(state)
    }

    func markFinished() {
        finished = true
    }

    func waitForCount(_ count: Int) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(5)
        while states.count < count, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(1))
        }
        return states.count >= count
    }

    func waitForFinish() async -> Bool {
        let deadline = ContinuousClock.now + .seconds(5)
        while !finished, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(1))
        }
        return finished
    }
}
