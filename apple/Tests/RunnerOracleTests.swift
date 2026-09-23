import CoreGraphics
import Foundation

@main @MainActor
enum RunnerOracleTests {
    static func main() async throws {
        await unavailableWithoutClient()
        await foregroundChecks()
        await alertsLockedAndTree()
        await queryFailures()
        await clientRoundTrip()
        await verifierSettle()
        await verifierForeground()
        await verifierText()
        await verifierTreeLockedAndAlerts()
        try await executorFailureLadder()
        print("Runner oracle tests passed")
    }

    private static func expect(_ condition: Bool, _ message: String) {
        precondition(condition, message)
    }

    private static func unavailableWithoutClient() async {
        let oracle = RunnerOracle()
        expect(await oracle.isLocked() == .unavailable, "nil client answers unavailable")
        expect(await oracle.springboardAlerts() == .unavailable, "nil client answers unavailable")
        expect(await oracle.treeText() == .unavailable, "nil client answers unavailable")
        expect(await oracle.isAppForeground(bundleID: "Safari") == .unavailable, "nil client answers unavailable")
    }

    private static func foregroundChecks() async {
        let fake = FakeRunner()
        let oracle = RunnerOracle(client: fake)

        fake.appStateResponse = .init(bundleID: "com.apple.mobilesafari", state: .foreground, springboardForeground: false)
        expect(await oracle.isAppForeground(bundleID: "com.apple.mobilesafari") == .value(.foreground(observed: "com.apple.mobilesafari")),
            "exact bundle ID matches")
        expect(await oracle.isAppForeground(bundleID: "Safari") == .value(.foreground(observed: "com.apple.mobilesafari")),
            "display name matches the bundle ID heuristically")
        expect(await oracle.isAppForeground(bundleID: "com.spotify.client") == .value(.mismatch(observed: "com.apple.mobilesafari")),
            "a different app is a mismatch")

        fake.appStateResponse = .init(bundleID: "com.apple.mobilesafari", state: .background, springboardForeground: false)
        expect(await oracle.isAppForeground(bundleID: "Safari") == .value(.mismatch(observed: "com.apple.mobilesafari")),
            "the matching app in the background is a mismatch")

        fake.appStateResponse = .init(bundleID: "com.apple.mobilesafari", state: .unknown, springboardForeground: false)
        guard case .value(.indeterminate) = await oracle.isAppForeground(bundleID: "Safari") else {
            preconditionFailure("unknown state must be indeterminate")
        }

        fake.appStateResponse = .init(bundleID: nil, state: .foreground, springboardForeground: true)
        expect(await oracle.isAppForeground(bundleID: RunnerOracle.springboardBundleID) == .value(.foreground(observed: RunnerOracle.springboardBundleID)),
            "SpringBoard foreground answers the SpringBoard query")
        expect(await oracle.isAppForeground(bundleID: "Safari") == .value(.mismatch(observed: RunnerOracle.springboardBundleID)),
            "SpringBoard foreground refutes other apps")

        fake.appStateResponse = .init(bundleID: nil, state: .unknown, springboardForeground: false)
        guard case .value(.indeterminate) = await oracle.isAppForeground(bundleID: "Safari") else {
            preconditionFailure("no foreground handle must be indeterminate")
        }
    }

    private static func alertsLockedAndTree() async {
        let fake = FakeRunner()
        let oracle = RunnerOracle(client: fake)

        fake.alertsResponse = .init(target: .springboard, alerts: [.init(title: "Allow?", buttonLabels: ["OK", "Cancel"])])
        expect(await oracle.springboardAlerts() == .value(fake.alertsResponse.alerts), "alerts pass through")

        fake.lockedResponse = .init(locked: true)
        expect(await oracle.isLocked() == .value(true), "lock state passes through")

        fake.treeResponse = .init(target: .foreground, tree: "Button Save")
        expect(await oracle.treeText(target: .springboard, maxDepth: 4) == .value("Button Save"), "tree text passes through")
        expect(fake.treeRequests.last?.0 == .springboard && fake.treeRequests.last?.1 == 4,
            "tree query forwards target and depth")
        _ = await oracle.treeText()
        expect(fake.treeRequests.last?.0 == .foreground && fake.treeRequests.last?.1 == 8,
            "tree defaults to the foreground app at depth 8")
    }

    private static func queryFailures() async {
        let fake = FakeRunner()
        fake.fails = true
        let oracle = RunnerOracle(client: fake)
        expect(await oracle.isLocked() == .failed("runner offline"), "runner errors surface as failed answers")
        guard case .failed(let message) = await oracle.isAppForeground(bundleID: "Safari") else {
            preconditionFailure("runner errors surface as failed answers")
        }
        expect(message == "runner offline", "the error message is preserved")
    }

    private static func clientRoundTrip() async {
        let box = RequestBox()
        let client = RunnerClient(baseURL: URL(string: "http://runner.test")!) { request in
            box.url = request.url?.absoluteString
            let response = AppStateResponse(bundleID: "com.apple.mobilesafari", state: .foreground, springboardForeground: false)
            let data = try JSONEncoder().encode(response)
            return (data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        let oracle = RunnerOracle(client: client)
        expect(await oracle.isAppForeground(bundleID: "Safari") == .value(.foreground(observed: "com.apple.mobilesafari")),
            "the oracle works over the real client")
        expect(box.url == "http://runner.test/state/app?target=foreground", "app state path and query")
    }

    private static func verifierSettle() async {
        var verifier = DevicePromptVerifier(capture: capture(sizes: [1000]))
        verifier.settleTimeout = 1
        var check = await verifier.checkFactory(.screenSettles)
        guard case .satisfied = await check() else { preconditionFailure("a steady screen must settle") }

        verifier = DevicePromptVerifier(capture: capture(sizes: [1000, 1200]))
        verifier.settleTimeout = 1
        check = await verifier.checkFactory(.screenSettles)
        guard case .satisfied = await check() else { preconditionFailure("noisy frames within tolerance must settle") }

        verifier = DevicePromptVerifier(capture: capture(sizes: [1000, 3000]))
        verifier.settleTimeout = 0.2
        check = await verifier.checkFactory(.screenSettles)
        guard case .failed(let evidence) = await check() else { preconditionFailure("a changing screen must not settle") }
        expect(evidence.contains("still changing"), "settle failure explains itself")

        verifier = DevicePromptVerifier()
        check = await verifier.checkFactory(.screenSettles)
        expect(await check() == .unverified, "no capture channel skips the settle rung")

        verifier = DevicePromptVerifier(capture: { _ in throw FakeRunner.FakeError() })
        check = await verifier.checkFactory(.screenSettles)
        expect(await check() == .unverified, "a failing stream skips the settle rung instead of failing the run")
    }

    private static func verifierForeground() async {
        let fake = FakeRunner()
        fake.appStateResponse = .init(bundleID: "com.apple.mobilesafari", state: .foreground, springboardForeground: false)
        var verifier = DevicePromptVerifier(oracle: RunnerOracle(client: fake))

        var check = await verifier.checkFactory(.appForeground(bundleID: "Safari"))
        guard case .satisfied = await check() else { preconditionFailure("foreground scalar must satisfy") }

        check = await verifier.checkFactory(.appForeground(bundleID: "com.spotify.client"))
        guard case .failed(let mismatch) = await check() else { preconditionFailure("wrong app must fail") }
        expect(mismatch.contains("mobilesafari"), "the mismatch names the observed app")

        fake.appStateResponse = .init(bundleID: nil, state: .unknown, springboardForeground: false)
        verifier = DevicePromptVerifier(oracle: RunnerOracle(client: fake), capture: capture(sizes: [1000]))
        verifier.settleTimeout = 1
        check = await verifier.checkFactory(.appForeground(bundleID: "Safari"))
        guard case .satisfied = await check() else { preconditionFailure("indeterminate scalar falls back to settle") }
    }

    private static func verifierText() async {
        let ocr: DevicePromptVerifier.RecognizeText = { _ in "Hello world" }
        var verifier = DevicePromptVerifier(capture: capture(sizes: [1000]), recognizeText: ocr)
        verifier.settleTimeout = 1

        var check = await verifier.checkFactory(.textAppears("hello"))
        guard case .satisfied = await check() else { preconditionFailure("visible text must satisfy") }

        check = await verifier.checkFactory(.textAppears("goodbye"))
        guard case .failed(let evidence) = await check() else { preconditionFailure("missing text must fail") }
        expect(evidence.contains("Screen text before") && evidence.contains("Screen text after") && evidence.contains("Hello world"),
            "text failure carries before/after OCR evidence")

        check = await verifier.checkFactory(.textDisappears("goodbye"))
        guard case .satisfied = await check() else { preconditionFailure("absent text satisfies disappearance") }

        check = await verifier.checkFactory(.textDisappears("hello"))
        guard case .failed = await check() else { preconditionFailure("lingering text must fail disappearance") }

        let fake = FakeRunner()
        fake.treeResponse = .init(target: .foreground, tree: "Button \"Save\" Label \"Cancel\"")
        verifier = DevicePromptVerifier(oracle: RunnerOracle(client: fake))
        check = await verifier.checkFactory(.textAppears("save"))
        guard case .satisfied = await check() else { preconditionFailure("tree fallback must satisfy") }
        check = await verifier.checkFactory(.textAppears("missing"))
        guard case .failed(let treeEvidence) = await check() else { preconditionFailure("tree fallback must fail") }
        expect(treeEvidence.contains("Tree excerpt"), "tree failure carries an excerpt")
    }

    private static func verifierTreeLockedAndAlerts() async {
        let fake = FakeRunner()
        fake.treeResponse = .init(target: .foreground, tree: "Button \"Save\" Label \"Cancel\"")
        var verifier = DevicePromptVerifier(oracle: RunnerOracle(client: fake))

        var check = await verifier.checkFactory(.treeContains("Cancel"))
        guard case .satisfied = await check() else { preconditionFailure("treeContains must match") }

        check = await verifier.checkFactory(.treeContains("zzz"))
        guard case .failed(let evidence) = await check() else { preconditionFailure("treeContains must refute") }
        expect(evidence.contains("Tree excerpt"), "tree refutation carries an excerpt")

        verifier = DevicePromptVerifier()
        check = await verifier.checkFactory(.treeContains("x"))
        expect(await check() == .unverified, "no oracle skips the tree rung")

        fake.lockedResponse = .init(locked: true)
        verifier = DevicePromptVerifier(oracle: RunnerOracle(client: fake), capture: capture(sizes: [1000]))
        check = await verifier.checkFactory(.screenSettles)
        guard case .failed(let locked) = await check() else { preconditionFailure("a locked phone must fail fast") }
        expect(locked.contains("locked"), "the locked failure says so")

        fake.lockedResponse = .init(locked: false)
        fake.alertsResponse = .init(target: .springboard, alerts: [.init(title: "Allow?", buttonLabels: ["OK", "Cancel"])])
        verifier = DevicePromptVerifier(oracle: RunnerOracle(client: fake))
        check = await verifier.checkFactory(.treeContains("zzz"))
        guard case .failed(let withAlert) = await check() else { preconditionFailure("failure expected") }
        expect(withAlert.contains("Alert on the phone") && withAlert.contains("Allow?"),
            "failures surface the showing alert")
    }

    private static func executorFailureLadder() async throws {
        let device = DeviceDescriptor(identifier: "phone", name: "Phone", transport: .bluetoothHID)

        var host = RecordingHost()
        try await DevicePromptExecutor.perform(.home, using: host, on: device)
        expect(host.pressed == ["home"], "no checker keeps single execution")

        host = RecordingHost()
        try await DevicePromptExecutor.perform(.home, using: host, on: device, checking: scriptedChecks([.satisfied("ok")]))
        expect(host.pressed == ["home"], "a satisfied check means no retry")

        host = RecordingHost()
        try await DevicePromptExecutor.perform(.home, using: host, on: device, checking: scriptedChecks([.failed("flake"), .satisfied("landed")]))
        expect(host.pressed == ["home"], "the idempotency re-check prevents an unneeded retry")

        host = RecordingHost()
        try await DevicePromptExecutor.perform(.home, using: host, on: device, checking: scriptedChecks([.failed("a"), .failed("b"), .satisfied("retried")]))
        expect(host.pressed == ["home", "home"], "one retry follows two failed checks")

        host = RecordingHost()
        do {
            try await DevicePromptExecutor.perform(.home, using: host, on: device, checking: scriptedChecks([.failed("a"), .failed("b"), .failed("final evidence")]))
            preconditionFailure("persistent failure must abort")
        } catch let error as DevicePromptVerificationError {
            expect(error.localizedDescription == "final evidence", "the evidence reaches the thrown error")
        }
        expect(host.pressed == ["home", "home"], "the action is retried at most once")
    }

    private static func scriptedChecks(_ outcomes: [DevicePromptCheckOutcome]) -> DevicePromptCheckFactory {
        let box = OutcomeBox(outcomes)
        return { _ in { box.next() } }
    }

    private static let pixel: CGImage = {
        let context = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        return context.makeImage()!
    }()

    private static func frame(capturedAt: Date, jpegSize: Int) -> PhoneScreenFrame {
        PhoneScreenFrame(id: UUID(), capturedAt: capturedAt, pixelWidth: 1, pixelHeight: 1,
            jpegData: Data(repeating: 0xAA, count: jpegSize), cgImage: pixel, sourceID: "test")
    }

    private static func capture(sizes: [Int]) -> DevicePromptVerifier.Capture {
        let box = SizeBox(sizes)
        return { barrier in
            try await Task.sleep(for: .milliseconds(5))
            return frame(capturedAt: barrier.addingTimeInterval(0.01), jpegSize: box.next())
        }
    }
}

@MainActor
private final class OutcomeBox {
    private var outcomes: [DevicePromptCheckOutcome]
    init(_ outcomes: [DevicePromptCheckOutcome]) { self.outcomes = outcomes }
    func next() -> DevicePromptCheckOutcome {
        outcomes.isEmpty ? .satisfied("ok") : outcomes.removeFirst()
    }
}

@MainActor
private final class SizeBox {
    private let sizes: [Int]
    private var index = 0
    init(_ sizes: [Int]) { self.sizes = sizes }
    func next() -> Int {
        defer { index += 1 }
        return sizes[index % sizes.count]
    }
}

private final class RequestBox: @unchecked Sendable {
    var url: String?
}

@MainActor
private final class RecordingHost: DeviceHost {
    let events = AsyncStream<DeviceHostEvent> { $0.finish() }
    var pressed: [String] = []

    func connect(_ device: DeviceDescriptor) async throws { }
    func disconnect(_ device: DeviceDescriptor) { }
    func tap(_ point: NormalizedPoint, on device: DeviceDescriptor) async throws { }
    func swipe(from start: NormalizedPoint, to end: NormalizedPoint, on device: DeviceDescriptor) async throws { }
    func type(_ text: String, on device: DeviceDescriptor) async throws { }
    func pressKey(_ key: DeviceKeyboardKey, on device: DeviceDescriptor) async throws {
        if case .home = key { pressed.append("home") } else { pressed.append("other") }
    }
}

private final class FakeRunner: PhoneRunnerServing, @unchecked Sendable {
    struct FakeError: LocalizedError {
        var errorDescription: String? { "runner offline" }
    }

    var appStateResponse = AppStateResponse(bundleID: nil, state: .unknown, springboardForeground: false)
    var alertsResponse = AlertsResponse(target: .springboard, alerts: [])
    var lockedResponse = LockedResponse(locked: false)
    var treeResponse = TreeResponse(target: .foreground, tree: "")
    var fails = false
    var treeRequests: [(RunnerTarget, Int?)] = []

    func health() async throws -> HealthResponse {
        HealthResponse(status: "ok", version: PhoneRunnerProtocol.version, deviceModel: "iPhone", osVersion: "26.0")
    }
    func tap(_ request: TapRequest) async throws { }
    func drag(_ request: DragRequest) async throws { }
    func swipe(_ request: SwipeRequest) async throws { }
    func pinch(_ request: PinchRequest) async throws { }
    func type(_ request: TypeRequest) async throws { }
    func pressKey(_ request: KeyRequest) async throws { }
    func pressButton(_ request: PressButtonRequest) async throws { }
    func openApp(_ request: OpenAppRequest) async throws { }
    func performAlertAction(_ request: AlertActionRequest) async throws { }

    func appState(target: RunnerTarget) async throws -> AppStateResponse {
        if fails { throw FakeError() }
        return appStateResponse
    }
    func tree(target: RunnerTarget, maxDepth: Int?) async throws -> TreeResponse {
        if fails { throw FakeError() }
        treeRequests.append((target, maxDepth))
        return treeResponse
    }
    func alerts(target: RunnerTarget) async throws -> AlertsResponse {
        if fails { throw FakeError() }
        return alertsResponse
    }
    func locked() async throws -> LockedResponse {
        if fails { throw FakeError() }
        return lockedResponse
    }
    func screenshot() async throws -> Data { Data() }
}
