import Foundation

/// Identity of a physical phone, detached from SwiftData so it can cross
/// concurrency boundaries.
struct DeviceDescriptor: Sendable, Hashable {
    var identifier: String
    var name: String
    var transport: DeviceTransport
}

/// Screen-space point normalised to 0...1 on each axis. The Bluetooth HID
/// mouse reports absolute X/Y in 0...32767, which iOS AssistiveTouch maps to
/// the full screen, so a normalised point is all a driver needs.
struct NormalizedPoint: Sendable, Hashable {
    var x: Double
    var y: Double
}

enum DeviceKeyboardKey: Sendable {
    case home, search, selectAll, addressBar, enter, escape, backspace, tab
}

enum DeviceHostEvent: Sendable {
    case discovered(DeviceDescriptor)
    case connectionChanged(identifier: String, state: DeviceConnectionState)
    /// The host learned a device's real Bluetooth address from an incoming
    /// pairing, replacing the placeholder stored on the device.
    case addressLearned(identifier: String, address: String)
}

/// Driver seam for whatever physically reaches the phone.
///
/// The Bluetooth production implementation follows the approach TapKit uses
/// (see docs/tapkit-reverse-engineering.md): the Mac publishes a Bluetooth
/// Classic HID service (a mouse with absolute X/Y plus a keyboard) that the
/// iPhone pairs with from Settings › Accessibility › Touch › AssistiveTouch ›
/// Devices, then streams HID input reports over the L2CAP interrupt channel.
/// `SimulatedDeviceHost` still stands in for the USB transport.
@MainActor
protocol DeviceHost: AnyObject {
    var events: AsyncStream<DeviceHostEvent> { get }

    func prepareForPairing() throws
    func connect(_ device: DeviceDescriptor) async throws
    func disconnect(_ device: DeviceDescriptor)

    func tap(_ point: NormalizedPoint, on device: DeviceDescriptor) async throws
    func swipe(from start: NormalizedPoint, to end: NormalizedPoint, on device: DeviceDescriptor) async throws
    func type(_ text: String, on device: DeviceDescriptor) async throws
    func pressKey(_ key: DeviceKeyboardKey, on device: DeviceDescriptor) async throws
    func openAssistiveTouchMenu(on device: DeviceDescriptor) async throws
}

extension DeviceHost {
    func prepareForPairing() throws {}
    func openAssistiveTouchMenu(on device: DeviceDescriptor) async throws {
        throw DeviceHostError.unsupportedInput("Opening AssistiveTouch is unavailable for this device.")
    }
    func pressKey(_ key: DeviceKeyboardKey, on device: DeviceDescriptor) async throws {
        throw DeviceHostError.unsupportedInput("Keyboard commands are unavailable for this device.")
    }
}

enum DeviceHostError: Error, LocalizedError {
    case notConnected(String)
    case connectionTimedOut(String)
    case unsupportedInput(String)

    var errorDescription: String? {
        switch self {
        case .notConnected(let name): "\(name) is not connected"
        case .connectionTimedOut(let name): "\(name) did not open its Bluetooth control channels. On the iPhone, enable AssistiveTouch and select this Mac under Devices › Bluetooth Devices."
        case .unsupportedInput(let message): message
        }
    }
}

/// Pretends to pair and drive phones with realistic delays.
@MainActor
final class SimulatedDeviceHost: DeviceHost {
    let events: AsyncStream<DeviceHostEvent>
    private let continuation: AsyncStream<DeviceHostEvent>.Continuation
    private var connected: Set<String> = []

    init() {
        let (stream, continuation) = AsyncStream<DeviceHostEvent>.makeStream()
        self.events = stream
        self.continuation = continuation
    }

    func connect(_ device: DeviceDescriptor) async throws {
        continuation.yield(.connectionChanged(identifier: device.identifier, state: .pairing))
        try await Task.sleep(for: .seconds(Double.random(in: 1...2.5)))
        connected.insert(device.identifier)
        continuation.yield(.connectionChanged(identifier: device.identifier, state: .connected))
    }

    func disconnect(_ device: DeviceDescriptor) {
        connected.remove(device.identifier)
        continuation.yield(.connectionChanged(identifier: device.identifier, state: .disconnected))
    }

    func tap(_ point: NormalizedPoint, on device: DeviceDescriptor) async throws {
        try ensureConnected(device)
        try await Task.sleep(for: .milliseconds(120))
    }

    func swipe(from start: NormalizedPoint, to end: NormalizedPoint, on device: DeviceDescriptor) async throws {
        try ensureConnected(device)
        try await Task.sleep(for: .milliseconds(350))
    }

    func type(_ text: String, on device: DeviceDescriptor) async throws {
        try ensureConnected(device)
        try await Task.sleep(for: .milliseconds(40 * text.count))
    }

    private func ensureConnected(_ device: DeviceDescriptor) throws {
        guard connected.contains(device.identifier) else {
            throw DeviceHostError.notConnected(device.name)
        }
    }
}
