import Foundation

@MainActor
final class RunnerDeviceHost: DeviceHost {
    let events: AsyncStream<DeviceHostEvent>
    private let continuation: AsyncStream<DeviceHostEvent>.Continuation
    private let runner: any PhoneRunnerServing

    init(runner: any PhoneRunnerServing) {
        let (stream, continuation) = AsyncStream<DeviceHostEvent>.makeStream()
        self.events = stream
        self.continuation = continuation
        self.runner = runner
    }

    func connect(_ device: DeviceDescriptor) async throws {
        continuation.yield(.connectionChanged(identifier: device.identifier, state: .pairing))
        _ = try await runner.health()
        continuation.yield(.connectionChanged(identifier: device.identifier, state: .connected))
    }

    func disconnect(_ device: DeviceDescriptor) {
        continuation.yield(.connectionChanged(identifier: device.identifier, state: .disconnected))
    }

    func canAutoConnect(_ device: DeviceDescriptor) -> Bool { true }

    func tap(_ point: NormalizedPoint, on device: DeviceDescriptor) async throws {
        try await runner.tap(TapRequest(point: RunnerPoint(x: point.x, y: point.y)))
    }

    func swipe(from start: NormalizedPoint, to end: NormalizedPoint, on device: DeviceDescriptor) async throws {
        try await runner.drag(DragRequest(from: RunnerPoint(x: start.x, y: start.y), to: RunnerPoint(x: end.x, y: end.y)))
    }

    func doubleTap(_ point: NormalizedPoint, on device: DeviceDescriptor) async throws {
        try await runner.tap(TapRequest(point: .init(x: point.x, y: point.y), tapCount: 2))
    }

    func longPress(_ point: NormalizedPoint, seconds: Double, on device: DeviceDescriptor) async throws {
        try await runner.tap(TapRequest(point: .init(x: point.x, y: point.y), holdDuration: seconds))
    }

    func drag(from start: NormalizedPoint, to end: NormalizedPoint, duration: Double,
              pressDuration: Double, holdDuration: Double, on device: DeviceDescriptor) async throws {
        try await runner.drag(DragRequest(from: .init(x: start.x, y: start.y), to: .init(x: end.x, y: end.y),
            duration: duration, pressDuration: pressDuration, holdDuration: holdDuration))
    }

    func openAppSwitcher(on device: DeviceDescriptor) async throws {
        try await drag(from: .init(x: 0.5, y: 0.99), to: .init(x: 0.5, y: 0.55),
            duration: 0.36, pressDuration: 0.5, holdDuration: 0.9, on: device)
    }

    func type(_ text: String, on device: DeviceDescriptor) async throws {
        try await KeyboardTyping.run(text) { character in
            try await runner.type(TypeRequest(text: String(character)))
        }
    }

    func pressKey(_ key: DeviceKeyboardKey, on device: DeviceDescriptor) async throws {
        if key == .home {
            try await runner.pressButton(PressButtonRequest(button: .home))
        } else if let runnerKey = KeyRequest.Key(rawValue: key.rawValue) {
            try await runner.pressKey(KeyRequest(key: runnerKey))
        } else {
            throw DeviceHostError.unsupportedInput("This key is unavailable on the phone runner.")
        }
    }

    func openAssistiveTouchMenu(on device: DeviceDescriptor) async throws {
        throw DeviceHostError.unsupportedInput("The on-device runner replaces AssistiveTouch, so its menu is unavailable.")
    }
}
