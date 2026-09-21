import Foundation

// swiftc -swift-version 6 ShortReel/Models/*.swift PhoneRunnerShared/PhoneRunnerProtocol.swift ShortReel/Services/PhoneRunner/RunnerClient.swift ShortReel/Services/DeviceHost.swift ShortReel/Services/PhoneRunner/RunnerDeviceHost.swift ShortReel/Services/DevicePrompts/{WarmUpPlaybook,DeviceWorkflow,DevicePromptPlanner,DevicePromptPlan}.swift Tests/RunnerDeviceHostTests.swift -o /tmp/sr-devicehost-tests
@main
enum RunnerDeviceHostTests {
    @MainActor
    static func main() async throws {
        let device = DeviceDescriptor(identifier: "AA:BB:CC:DD:EE:15", name: "Test iPhone", transport: .bluetoothHID)

        try await tapMapsToRunnerPoint(device)
        try await swipeMapsToDefaultDrag(device)
        try await typingPreservesLiteralText(device)
        try await homeKeyMapsToHomeButton(device)
        try await keyboardKeysMapToRunner(device)
        try await assistiveTouchMenuThrowsUnsupported(device)
        try await connectProbesHealth(device)
        try await connectSurfacesHealthFailure(device)
        try await runnerFailuresPropagate(device)
        try await canAutoConnectIsAlwaysTrue(device)

        let runner = MockRunner()
        let host = RunnerDeviceHost(runner: runner)
        try await host.doubleTap(.init(x: 0.2, y: 0.3), on: device)
        try await host.longPress(.init(x: 0.4, y: 0.5), seconds: 1.2, on: device)
        precondition(runner.taps[0].tapCount == 2 && runner.taps[0].point == .init(x: 0.2, y: 0.3))
        precondition(runner.taps[1].holdDuration == 1.2 && runner.taps[1].point == .init(x: 0.4, y: 0.5))
        try await host.drag(from: .init(x: 0.1, y: 0.9), to: .init(x: 0.8, y: 0.2),
            duration: 0.6, pressDuration: 0.8, holdDuration: 0.4, on: device)
        let wire = try JSONEncoder().encode(runner.drags[0])
        let drag = try JSONDecoder().decode(DragRequest.self, from: wire)
        precondition(drag.from == .init(x: 0.1, y: 0.9) && drag.to == .init(x: 0.8, y: 0.2))
        precondition(drag.duration == 0.6 && drag.pressDuration == 0.8 && drag.holdDuration == 0.4)
        try await host.openAppSwitcher(on: device)
        precondition(runner.drags.count == 2 && runner.drags[1].holdDuration == 0.9)
        let legacy = try JSONDecoder().decode(TapRequest.self,
            from: Data(#"{"target":"foreground","point":{"x":0.5,"y":0.5},"settle":"idle"}"#.utf8))
        precondition(legacy.tapCount == nil && legacy.holdDuration == nil)

        print("Runner device host tests passed")
    }

    @MainActor
    private static func tapMapsToRunnerPoint(_ device: DeviceDescriptor) async throws {
        let runner = MockRunner()
        let host = RunnerDeviceHost(runner: runner)
        try await host.tap(NormalizedPoint(x: 0.25, y: 0.75), on: device)
        precondition(runner.taps.count == 1)
        let request = runner.taps[0]
        precondition(request.point == RunnerPoint(x: 0.25, y: 0.75), "Unexpected tap point: \(request.point)")
        precondition(request.target == .foreground && request.settle == .idle)
    }

    @MainActor
    private static func swipeMapsToDefaultDrag(_ device: DeviceDescriptor) async throws {
        let runner = MockRunner()
        let host = RunnerDeviceHost(runner: runner)
        try await host.swipe(from: NormalizedPoint(x: 0.5, y: 0.75), to: NormalizedPoint(x: 0.5, y: 0.25), on: device)
        precondition(runner.drags.count == 1)
        let request = runner.drags[0]
        precondition(request.from == RunnerPoint(x: 0.5, y: 0.75), "Unexpected drag start: \(request.from)")
        precondition(request.to == RunnerPoint(x: 0.5, y: 0.25), "Unexpected drag end: \(request.to)")
        precondition(request.duration == 0.4, "Swipe must use the contract's default duration, got \(request.duration)")
        precondition(request.curve == .linear && request.target == .foreground && request.settle == .idle)
    }

    @MainActor
    private static func typingPreservesLiteralText(_ device: DeviceDescriptor) async throws {
        let runner = MockRunner()
        let host = RunnerDeviceHost(runner: runner)
        let literal = "  Keep CASE; then \"quotes\" & emoji 🎬\nNext line  "
        try await host.type(literal, on: device)
        precondition(runner.types.count == literal.count)
        precondition(runner.types.allSatisfy { $0.text.count == 1 }, "Typing was sent as a bulk insert")
        precondition(runner.types.map(\.text).joined() == literal, "Typed characters changed the literal text")
        precondition(runner.types.allSatisfy { $0.target == .foreground && $0.settle == .idle })
    }

    @MainActor
    private static func homeKeyMapsToHomeButton(_ device: DeviceDescriptor) async throws {
        let runner = MockRunner()
        let host = RunnerDeviceHost(runner: runner)
        try await host.pressKey(.home, on: device)
        precondition(runner.buttons.count == 1)
        precondition(runner.buttons[0].button == .home)
    }

    @MainActor
    private static func keyboardKeysMapToRunner(_ device: DeviceDescriptor) async throws {
        for key in DeviceKeyboardKey.allCases where key != .home {
            let runner = MockRunner()
            let host = RunnerDeviceHost(runner: runner)
            try await host.pressKey(key, on: device)
            precondition(runner.keys.count == 1)
            precondition(runner.keys[0].key.rawValue == String(describing: key))
            precondition(runner.buttons.isEmpty)

        }
    }

    @MainActor
    private static func assistiveTouchMenuThrowsUnsupported(_ device: DeviceDescriptor) async throws {
        let runner = MockRunner()
        let host = RunnerDeviceHost(runner: runner)
        do {
            try await host.openAssistiveTouchMenu(on: device)
            preconditionFailure("AssistiveTouch menu reached the runner")
        } catch DeviceHostError.unsupportedInput { }
    }

    @MainActor
    private static func connectProbesHealth(_ device: DeviceDescriptor) async throws {
        let runner = MockRunner()
        let host = RunnerDeviceHost(runner: runner)
        let states = collectConnectionStates(host, count: 2)
        try await host.connect(device)
        let connectedStates = await states.value
        precondition(connectedStates == [.pairing, .connected])
        precondition(runner.healthCalls == 1, "Connect must be a health probe")
    }

    @MainActor
    private static func connectSurfacesHealthFailure(_ device: DeviceDescriptor) async throws {
        let runner = MockRunner()
        runner.healthError = MockRunner.RunnerFailure.refused
        let host = RunnerDeviceHost(runner: runner)
        let states = collectConnectionStates(host, count: 1)
        do {
            try await host.connect(device)
            preconditionFailure("Unhealthy runner connected")
        } catch MockRunner.RunnerFailure.refused { }
        let failedStates = await states.value
        precondition(failedStates == [.pairing], "A failed health probe must not report connected")
        host.disconnect(device)
    }

    @MainActor
    private static func runnerFailuresPropagate(_ device: DeviceDescriptor) async throws {
        let runner = MockRunner()
        runner.actionError = MockRunner.RunnerFailure.refused
        let host = RunnerDeviceHost(runner: runner)
        do {
            try await host.tap(NormalizedPoint(x: 0.5, y: 0.5), on: device)
            preconditionFailure("Runner error did not propagate")
        } catch MockRunner.RunnerFailure.refused { }
    }

    @MainActor
    private static func canAutoConnectIsAlwaysTrue(_ device: DeviceDescriptor) async throws {
        let host = RunnerDeviceHost(runner: MockRunner())
        precondition(host.canAutoConnect(device))
    }

    @MainActor
    private static func collectConnectionStates(_ host: RunnerDeviceHost, count: Int) -> Task<[DeviceConnectionState], Never> {
        Task { @MainActor in
            var states: [DeviceConnectionState] = []
            for await event in host.events {
                if case .connectionChanged(_, let state) = event {
                    states.append(state)
                }
                if states.count == count { break }
            }
            return states
        }
    }
}

private final class MockRunner: PhoneRunnerServing, @unchecked Sendable {
    enum RunnerFailure: Error { case refused }

    var healthError: Error?
    var actionError: Error?
    private(set) var healthCalls = 0
    private(set) var taps: [TapRequest] = []
    private(set) var drags: [DragRequest] = []
    private(set) var types: [TypeRequest] = []
    private(set) var keys: [KeyRequest] = []
    private(set) var buttons: [PressButtonRequest] = []

    func health() async throws -> HealthResponse {
        healthCalls += 1
        if let healthError { throw healthError }
        return HealthResponse(status: "ok", version: PhoneRunnerProtocol.version, deviceModel: "iPhone16,1", osVersion: "18.0")
    }

    func tap(_ request: TapRequest) async throws {
        taps.append(request)
        if let actionError { throw actionError }
    }

    func drag(_ request: DragRequest) async throws {
        drags.append(request)
        if let actionError { throw actionError }
    }

    func swipe(_ request: SwipeRequest) async throws { }
    func pinch(_ request: PinchRequest) async throws { }

    func type(_ request: TypeRequest) async throws {
        types.append(request)
        if let actionError { throw actionError }
    }

    func pressKey(_ request: KeyRequest) async throws {
        keys.append(request)
        if let actionError { throw actionError }
    }
    func pressButton(_ request: PressButtonRequest) async throws {
        buttons.append(request)
        if let actionError { throw actionError }
    }

    func openApp(_ request: OpenAppRequest) async throws { }
    func performAlertAction(_ request: AlertActionRequest) async throws { }

    func appState(target: RunnerTarget) async throws -> AppStateResponse {
        AppStateResponse(bundleID: nil, state: .foreground, springboardForeground: false)
    }

    func tree(target: RunnerTarget, maxDepth: Int?) async throws -> TreeResponse {
        TreeResponse(target: target, tree: "")
    }

    func alerts(target: RunnerTarget) async throws -> AlertsResponse {
        AlertsResponse(target: target, alerts: [])
    }

    func locked() async throws -> LockedResponse {
        LockedResponse(locked: false)
    }

    func screenshot() async throws -> Data { Data() }
}
