import Foundation

// swiftc -swift-version 6 ShortReel/Models/*.swift ShortReel/Services/DeviceHost.swift ShortReel/Services/DevicePrompts/DevicePromptPlan.swift ShortReel/Services/DevicePrompts/DevicePromptPlanner.swift ShortReel/Services/DevicePrompts/DevicePromptExecutor.swift Tests/DevicePromptExecutorTests.swift -o /tmp/shortreel-prompt-executor-tests
@main
enum DevicePromptExecutorTests {
    @MainActor
    static func main() async throws {
        let selectedDevice = DeviceDescriptor(
            identifier: "selected-phone-identifier",
            name: "Selected iPhone",
            transport: .bluetoothHID
        )

        try await openingAppTargetsSelectedDevice(selectedDevice)
        try await swipeDirections(selectedDevice)
        try await typingPreservesLiteralText(selectedDevice)
        try await driverFailureStopsSequence(selectedDevice)
        try await cancellationPreventsEnter(selectedDevice)
        try await invalidTapDoesNotReachDriver(selectedDevice)
        try await visualInputsTargetSelectedDevice(selectedDevice)
        try await editingShortcutsRemainAtomic(selectedDevice)

        print("Device prompt executor tests passed")
    }

    @MainActor
    private static func openingAppTargetsSelectedDevice(_ device: DeviceDescriptor) async throws {
        let host = RecordingDeviceHost()
        try await DevicePromptExecutor.perform(.openApp("App Store"), using: host, on: device)
        expect(host, [.key("home"), .key("search"), .key("selectAll"), .text("App Store"), .key("enter")], on: device)
    }

    @MainActor
    private static func swipeDirections(_ device: DeviceDescriptor) async throws {
        let host = RecordingDeviceHost()
        for direction in PhoneSwipeDirection.allCases {
            try await DevicePromptExecutor.perform(.swipe(direction), using: host, on: device)
        }
        expect(host, [
            .swipe(.init(x: 0.5, y: 0.75), .init(x: 0.5, y: 0.25)),
            .swipe(.init(x: 0.5, y: 0.25), .init(x: 0.5, y: 0.75)),
            .swipe(.init(x: 0.75, y: 0.5), .init(x: 0.25, y: 0.5)),
            .swipe(.init(x: 0.25, y: 0.5), .init(x: 0.75, y: 0.5)),
        ], on: device)
    }

    @MainActor
    private static func typingPreservesLiteralText(_ device: DeviceDescriptor) async throws {
        let host = RecordingDeviceHost()
        let literal = "  Keep CASE; then \"quotes\" & punctuation!\nNext line  "
        try await DevicePromptExecutor.perform(.typeText(literal), using: host, on: device)
        expect(host, [.text(literal)], on: device)
    }

    @MainActor
    private static func driverFailureStopsSequence(_ device: DeviceDescriptor) async throws {
        let host = RecordingDeviceHost()
        host.failureOn = .text("Safari")
        do {
            try await DevicePromptExecutor.perform(.openApp("Safari"), using: host, on: device)
            preconditionFailure("Driver failure did not propagate")
        } catch RecordingDeviceHost.DriverFailure.refused {
            // A refused text report must prevent the subsequent Enter key.
        }
        expect(host, [.key("home"), .key("search"), .key("selectAll"), .text("Safari")], on: device)
    }

    @MainActor
    private static func cancellationPreventsEnter(_ device: DeviceDescriptor) async throws {
        let host = RecordingDeviceHost()
        host.cancelWhenTyping = true
        let execution = Task { @MainActor in
            try await DevicePromptExecutor.perform(.openApp("Settings"), using: host, on: device)
        }
        do {
            try await execution.value
            preconditionFailure("Cancelled execution did not throw")
        } catch is CancellationError {
            // Cancellation after typing must not select a search result.
        }
        expect(host, [.key("home"), .key("search"), .key("selectAll"), .text("Settings")], on: device)
    }

    @MainActor
    private static func invalidTapDoesNotReachDriver(_ device: DeviceDescriptor) async throws {
        let host = RecordingDeviceHost()
        for point in [NormalizedPoint(x: .nan, y: 0.5), .init(x: 0.5, y: 1.1)] {
            do {
                try await DevicePromptExecutor.perform(.tap(point.x, point.y), using: host, on: device)
                preconditionFailure("Invalid coordinate reached driver")
            } catch is PhonePromptPlanningError { }
        }
        expect(host, [], on: device)
    }

    @MainActor
    private static func visualInputsTargetSelectedDevice(_ device: DeviceDescriptor) async throws {
        let host = RecordingDeviceHost()
        try await DevicePromptExecutor.perform(.drag(0.2, 0.4, 0.8, 0.6), using: host, on: device)
        try await DevicePromptExecutor.perform(.press(.search), using: host, on: device)
        expect(host, [.swipe(.init(x: 0.2, y: 0.4), .init(x: 0.8, y: 0.6)), .key("search")], on: device)
        do {
            try await DevicePromptExecutor.perform(.drag(0, 0, .nan, 1), using: host, on: device)
            preconditionFailure("Invalid drag reached the driver")
        } catch is PhonePromptPlanningError { }
        precondition(host.commands.count == 2)
    }

    @MainActor
    private static func editingShortcutsRemainAtomic(_ device: DeviceDescriptor) async throws {
        for (key, name): (PhoneKey, String) in [(.selectAll, "selectAll"), (.addressBar, "addressBar")] {
            let host = RecordingDeviceHost()
            try await DevicePromptExecutor.perform(.press(key), using: host, on: device)
            // The visual loop must be able to observe the selected field after
            // this shortcut, before any typing or subsequent key is dispatched.
            expect(host, [.key(name)], on: device)
        }
        let failing = RecordingDeviceHost()
        failing.failureOn = .key("addressBar")
        do {
            try await DevicePromptExecutor.perform(.press(.addressBar), using: failing, on: device)
            preconditionFailure("Address-bar shortcut failure did not propagate")
        } catch RecordingDeviceHost.DriverFailure.refused { }
        expect(failing, [.key("addressBar")], on: device)
    }

    @MainActor
    private static func expect(_ host: RecordingDeviceHost, _ inputs: [RecordingDeviceHost.Input], on device: DeviceDescriptor) {
        let expected = inputs.map { RecordingDeviceHost.Command(input: $0, device: device) }
        precondition(host.commands == expected, "Unexpected device input: \(host.commands), expected \(expected)")
    }
}

@MainActor
private final class RecordingDeviceHost: DeviceHost {
    enum Input: Equatable {
        case key(String)
        case text(String)
        case tap(NormalizedPoint)
        case swipe(NormalizedPoint, NormalizedPoint)
    }

    struct Command: Equatable {
        let input: Input
        let device: DeviceDescriptor
    }

    enum DriverFailure: Error {
        case refused
    }

    let events: AsyncStream<DeviceHostEvent> = AsyncStream { $0.finish() }
    var commands: [Command] = []
    var failureOn: Input?
    var cancelWhenTyping = false

    func connect(_ device: DeviceDescriptor) async throws { }
    func disconnect(_ device: DeviceDescriptor) { }

    func tap(_ point: NormalizedPoint, on device: DeviceDescriptor) async throws {
        try record(.tap(point), on: device)
    }

    func swipe(from start: NormalizedPoint, to end: NormalizedPoint, on device: DeviceDescriptor) async throws {
        try record(.swipe(start, end), on: device)
    }

    func type(_ text: String, on device: DeviceDescriptor) async throws {
        try record(.text(text), on: device)
        if cancelWhenTyping {
            withUnsafeCurrentTask { $0?.cancel() }
        }
    }

    func pressKey(_ key: DeviceKeyboardKey, on device: DeviceDescriptor) async throws {
        let name: String = switch key {
        case .home: "home"
        case .search: "search"
        case .selectAll: "selectAll"
        case .addressBar: "addressBar"
        case .enter: "enter"
        case .escape: "escape"
        case .backspace: "backspace"
        case .tab: "tab"
        }
        try record(.key(name), on: device)
    }

    private func record(_ input: Input, on device: DeviceDescriptor) throws {
        commands.append(.init(input: input, device: device))
        if input == failureOn { throw DriverFailure.refused }
    }
}
