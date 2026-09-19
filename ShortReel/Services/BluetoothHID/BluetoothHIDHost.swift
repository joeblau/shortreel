import CoreBluetooth
import Foundation
import OSLog

private let log = Logger(subsystem: "com.joeblau.shortreel", category: "BluetoothHID")

/// Real device host: publishes this Mac as a Bluetooth Classic HID
/// mouse + keyboard (the TapKit approach — see docs/tapkit-reverse-engineering.md)
/// and drives iPhones that pair with it from AssistiveTouch.
///
/// BluetoothDiscovery initiates bonding with the selected phone. `connect`
/// requests a bonded reconnect and waits for both HID channels before reporting
/// that the phone is controllable.
@MainActor
final class BluetoothHIDHost: DeviceHost {
    let events: AsyncStream<DeviceHostEvent>
    private let continuation: AsyncStream<DeviceHostEvent>.Continuation
    private let bridge = CBHIDBridge()

    private var started = false
    /// Device identifiers currently waiting for a phone to pair.
    private var waiting: Set<String> = []
    /// Device identifier → continuation to resume once its phone connects.
    private var pending: [String: CheckedContinuation<Void, Error>] = [:]
    private var connectionTimeouts: [String: Task<Void, Never>] = [:]
    /// Normalized Bluetooth address → device identifier, learned on connect.
    private var identifiersByAddress: [String: String] = [:]
    /// Device identifier → normalized Bluetooth address.
    private var addressesByIdentifier: [String: String] = [:]
    /// Addresses with both HID channels open.
    private var liveAddresses: Set<String> = []

    init() {
        let (stream, continuation) = AsyncStream<DeviceHostEvent>.makeStream()
        self.events = stream
        self.continuation = continuation

        bridge.onLog = { message in log.info("\(message, privacy: .public)") }
        bridge.onPeerChannelsChanged = { [weak self] state in
            let address = state.address
            let name = state.name
            let both = state.hasControlChannel && state.hasInterruptChannel
            Task { @MainActor in self?.peerChannelsChanged(address: address, name: name, fullyOpen: both) }
        }
        bridge.onPeerDisconnected = { [weak self] address in
            Task { @MainActor in self?.peerDisconnected(address: address) }
        }
        bridge.onConnectionFailed = { [weak self] address, error in
            Task { @MainActor in
                guard let self, let identifier = self.identifiersByAddress[address] else { return }
                self.failPendingConnection(identifier, error: error)
            }
        }
    }

    // MARK: - DeviceHost

    func prepareForPairing() throws {
        try ensureStarted()
    }

    func connect(_ device: DeviceDescriptor) async throws {
        try Task.checkCancellation()
        try ensureStarted()
        registerAddress(for: device)
        continuation.yield(.connectionChanged(identifier: device.identifier, state: .pairing))

        guard let address = normalizedAddress(for: device) else {
            continuation.yield(.connectionChanged(identifier: device.identifier, state: .disconnected))
            throw DeviceHostError.notConnected(device.name)
        }
        if liveAddresses.contains(address) {
            continuation.yield(.connectionChanged(identifier: device.identifier, state: .connected))
            return
        }

        waiting.insert(device.identifier)
        guard pending[device.identifier] == nil else { return }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cc: CheckedContinuation<Void, Error>) in
                pending[device.identifier] = cc
                connectionTimeouts[device.identifier] = Task { [weak self] in
                    // A first connection can trigger the system permission prompt.
                    // Surface a denial promptly instead of waiting for HID channels
                    // that macOS cannot deliver without authorization.
                    for _ in 0..<180 {
                        do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
                        guard let self, self.pending[device.identifier] != nil else { return }
                        do { try self.ensureBluetoothPermission() }
                        catch {
                            self.failPendingConnection(device.identifier, error: error)
                            return
                        }
                    }
                    self?.failPendingConnection(device.identifier,
                        error: DeviceHostError.connectionTimedOut(device.name))
                }
                bridge.requestConnection(address: address)
            }
        } onCancel: { [weak self] in
            Task { @MainActor in
                self?.failPendingConnection(device.identifier, error: CancellationError())
            }
        }
    }

    func disconnect(_ device: DeviceDescriptor) {
        connectionTimeouts.removeValue(forKey: device.identifier)?.cancel()
        waiting.remove(device.identifier)
        if let cc = pending.removeValue(forKey: device.identifier) {
            cc.resume(throwing: DeviceHostError.notConnected(device.name))
        }
        if let address = addressesByIdentifier[device.identifier] {
            liveAddresses.remove(address)
            bridge.disconnectPeer(withAddress: address)
        }
        continuation.yield(.connectionChanged(identifier: device.identifier, state: .disconnected))
    }

    func tap(_ point: NormalizedPoint, on device: DeviceDescriptor) async throws {
        try ensureConnected(device)
        try Task.checkCancellation()
        defer { try? send(mouseReport(buttons: 0, point: point), to: device) }
        try send(mouseReport(buttons: 0, point: point), to: device)
        try await Task.sleep(for: .milliseconds(30))
        try send(mouseReport(buttons: 1, point: point), to: device)
        try await Task.sleep(for: .milliseconds(60))
        try send(mouseReport(buttons: 0, point: point), to: device)
    }

    func openAssistiveTouchMenu(on device: DeviceDescriptor) async throws {
        try ensureConnected(device)
        try Task.checkCancellation()
        let point = NormalizedPoint(x: 0.5, y: 0.5)
        defer { try? send(mouseReport(buttons: 0, point: point), to: device) }
        try send(mouseReport(buttons: 0, point: point), to: device)
        try send(mouseReport(buttons: 0x02, point: point), to: device)
        try await Task.sleep(for: .milliseconds(60))
        try Task.checkCancellation()
        try send(mouseReport(buttons: 0, point: point), to: device)
    }

    /// A visible, non-clicking check of the actual input path.
    func testPointer(on device: DeviceDescriptor) async throws {
        try ensureConnected(device)
        for point in [NormalizedPoint(x: 0.25, y: 0.25), NormalizedPoint(x: 0.75, y: 0.75), NormalizedPoint(x: 0.5, y: 0.5)] {
            try send(mouseReport(buttons: 0, point: point), to: device)
            try await Task.sleep(for: .milliseconds(500))
        }
    }

    func swipe(from start: NormalizedPoint, to end: NormalizedPoint, on device: DeviceDescriptor) async throws {
        try ensureConnected(device)
        try Task.checkCancellation()
        var lastPoint = start
        defer { try? send(mouseReport(buttons: 0, point: lastPoint), to: device) }
        let steps = 12
        try send(mouseReport(buttons: 1, point: start), to: device)
        for step in 1...steps {
            try await Task.sleep(for: .milliseconds(25))
            let t = Double(step) / Double(steps)
            let point = NormalizedPoint(
                x: start.x + (end.x - start.x) * t,
                y: start.y + (end.y - start.y) * t
            )
            lastPoint = point
            try send(mouseReport(buttons: 1, point: point), to: device)
        }
        try send(mouseReport(buttons: 0, point: end), to: device)
    }

    func type(_ text: String, on device: DeviceDescriptor) async throws {
        try ensureConnected(device)
        guard text.allSatisfy({ HIDKeyMap.lookup($0) != nil }) else {
            throw DeviceHostError.unsupportedInput("This keyboard currently supports English letters, numbers, and punctuation. The text contains an unsupported character.")
        }
        defer { try? send(keyboardReport(modifiers: 0, keycode: 0), to: device) }
        for character in text {
            try Task.checkCancellation()
            guard let key = HIDKeyMap.lookup(character) else { continue }
            try send(keyboardReport(modifiers: key.shift ? 0x02 : 0, keycode: key.code), to: device)
            try await Task.sleep(for: .milliseconds(12))
            try send(keyboardReport(modifiers: 0, keycode: 0), to: device)
            try await Task.sleep(for: .milliseconds(12))
        }
    }

    func pressKey(_ key: DeviceKeyboardKey, on device: DeviceDescriptor) async throws {
        try ensureConnected(device)
        try Task.checkCancellation()
        let code: UInt8
        let modifiers: UInt8
        switch key {
        case .home:
            try await goHome(on: device)
            return
        case .search: (code, modifiers) = (0x2C, 0x08) // Command-Space
        case .selectAll: (code, modifiers) = (0x04, 0x08)
        case .addressBar: (code, modifiers) = (0x0F, 0x08) // Command-L
        case .enter: (code, modifiers) = (0x28, 0)
        case .escape: (code, modifiers) = (0x29, 0)
        case .backspace: (code, modifiers) = (0x2A, 0)
        case .tab: (code, modifiers) = (0x2B, 0)
        }
        defer { try? send(keyboardReport(modifiers: 0, keycode: 0), to: device) }
        try send(keyboardReport(modifiers: modifiers, keycode: code), to: device)
        try await Task.sleep(for: .milliseconds(40))
        try send(keyboardReport(modifiers: 0, keycode: 0), to: device)
    }

    /// Use a quick AssistiveTouch edge flick for Home. The slow drag with
    /// an endpoint hold opened App Switcher on the attached iPhone, so retain
    /// motion through the final report and release immediately.
    private func goHome(on device: DeviceDescriptor) async throws {
        try Task.checkCancellation()
        let start = NormalizedPoint(x: 0.5, y: 0.99)
        let end = NormalizedPoint(x: 0.5, y: 0.45)
        var lastPoint = start
        defer { try? send(mouseReport(buttons: 0, point: lastPoint), to: device) }

        try send(mouseReport(buttons: 0, point: start), to: device)
        try await Task.sleep(for: .milliseconds(30))
        try send(mouseReport(buttons: 1, point: start), to: device)

        let steps = 20
        for step in 1...steps {
            try await Task.sleep(for: .milliseconds(10))
            try Task.checkCancellation()
            let t = Double(step) / Double(steps)
            let point = NormalizedPoint(x: start.x, y: start.y + (end.y - start.y) * t)
            try send(mouseReport(buttons: 1, point: point), to: device)
            lastPoint = point
        }
        try send(mouseReport(buttons: 0, point: end), to: device)
    }

    // MARK: - Bridge events

    private func peerChannelsChanged(address: String, name: String, fullyOpen: Bool) {
        if fullyOpen {
            // Bonding can open channels before the registry saves the phone.
            liveAddresses.insert(address)
            let identifier: String
            if let known = resolveIdentifier(for: address) {
                identifier = known
            } else {
                // A phone can initiate pairing while the scan sheet is open.
                // Both real HID channels prove its identity; no manual entry
                // or guessed address is needed to save that phone.
                guard address.count == 12, address.allSatisfy(\.isHexDigit) else { return }
                identifier = Self.format(address: address)
                continuation.yield(.discovered(DeviceDescriptor(identifier: identifier,
                    name: name.isEmpty ? "iPhone" : name, transport: .bluetoothHID)))
            }
            identifiersByAddress[address] = identifier
            addressesByIdentifier[identifier] = address
            waiting.remove(identifier)
            continuation.yield(.connectionChanged(identifier: identifier, state: .connected))
            pending.removeValue(forKey: identifier)?.resume()
            connectionTimeouts.removeValue(forKey: identifier)?.cancel()
        } else if liveAddresses.contains(address) {
            // One of the two HID channels closed — the phone is gone.
            liveAddresses.remove(address)
            if let identifier = identifiersByAddress[address] {
                continuation.yield(.connectionChanged(identifier: identifier, state: .disconnected))
            }
        }
    }

    private func peerDisconnected(address: String) {
        liveAddresses.remove(address)
        guard let identifier = identifiersByAddress[address] else { return }
        if waiting.contains(identifier) { return } // will reconnect via a fresh connect()
        continuation.yield(.connectionChanged(identifier: identifier, state: .disconnected))
    }

    /// Only the address selected in discovery may control a saved device.
    private func resolveIdentifier(for address: String) -> String? {
        identifiersByAddress[address]
    }

    // MARK: - Reports

    private func send(_ report: [UInt8], to device: DeviceDescriptor) throws {
        guard let address = addressesByIdentifier[device.identifier] ?? normalizedAddress(for: device) else {
            throw DeviceHostError.notConnected(device.name)
        }
        do {
            try bridge.sendReport(Data(report), toPeerWithAddress: address)
        } catch {
            liveAddresses.remove(address)
            continuation.yield(.connectionChanged(identifier: device.identifier, state: .disconnected))
            throw error
        }
    }

    /// Report ID 2: 4 button bytes, then absolute X and Y as little-endian
    /// 16-bit values in 0...32767 (iOS maps that to the whole screen).
    private func mouseReport(buttons: UInt32, point: NormalizedPoint) -> [UInt8] {
        func axis(_ value: Double) -> (UInt8, UInt8) {
            let scaled = UInt16(max(0, min(1, value)) * 32767)
            return (UInt8(scaled & 0xFF), UInt8(scaled >> 8))
        }
        let (xLo, xHi) = axis(point.x)
        let (yLo, yHi) = axis(point.y)
        return [
            0xA1, 0x02,
            UInt8(buttons & 0xFF), UInt8((buttons >> 8) & 0xFF),
            UInt8((buttons >> 16) & 0xFF), UInt8((buttons >> 24) & 0xFF),
            xLo, xHi, yLo, yHi,
        ]
    }

    /// Report ID 1: modifier byte, reserved byte, six keycodes.
    private func keyboardReport(modifiers: UInt8, keycode: UInt8) -> [UInt8] {
        [0xA1, 0x01, modifiers, 0x00, keycode, 0x00, 0x00, 0x00, 0x00, 0x00]
    }

    // MARK: - Helpers

    private func ensureStarted() throws {
        // Permission can change after the bridge has already been initialized.
        try ensureBluetoothPermission()
        guard !started else { return }
        let name = Host.current().localizedName ?? "ShortReel"
        do {
            try bridge.start(withServiceName: name, serviceRecord: HIDServiceRecord.makeRecord(serviceName: name))
        } catch {
            throw error
        }
        started = true
        try ensureBluetoothPermission()
    }

    private func ensureConnected(_ device: DeviceDescriptor) throws {
        try ensureBluetoothPermission()
        let address = addressesByIdentifier[device.identifier] ?? normalizedAddress(for: device)
        guard let address, liveAddresses.contains(address) else {
            throw DeviceHostError.notConnected(device.name)
        }
    }

    private func ensureBluetoothPermission() throws {
        let message: String
        switch CBManager.authorization {
        case .denied:
            message = "Bluetooth access is disabled for ShortReel. Allow ShortReel in System Settings → Privacy & Security → Bluetooth, then reconnect."
        case .restricted:
            message = "Bluetooth access is restricted on this Mac. Ask your Mac administrator to allow Bluetooth for ShortReel, then reconnect."
        case .notDetermined, .allowedAlways:
            return
        @unknown default:
            message = "macOS could not confirm Bluetooth permission for ShortReel. Check System Settings → Privacy & Security → Bluetooth, then reconnect."
        }
        throw NSError(domain: "ShortReel.BluetoothPermission", code: CBManager.authorization.rawValue,
                      userInfo: [NSLocalizedDescriptionKey: message])
    }

    private func failPendingConnection(_ identifier: String, error: Error) {
        guard let pending = pending.removeValue(forKey: identifier) else { return }
        waiting.remove(identifier)
        connectionTimeouts.removeValue(forKey: identifier)?.cancel()
        if let address = addressesByIdentifier[identifier] {
            bridge.cancelConnectionRequest(address: address)
        }
        continuation.yield(.connectionChanged(identifier: identifier, state: .disconnected))
        pending.resume(throwing: error)
    }

    /// Registers the device's stored Bluetooth address, if it holds one.
    private func registerAddress(for device: DeviceDescriptor) {
        guard let address = normalizedAddress(for: device) else { return }
        identifiersByAddress[address] = device.identifier
        addressesByIdentifier[device.identifier] = address
    }

    /// A stored identifier is a real address only if it looks like one —
    /// placeholders ("pending-…", random IDs from older stores) are ignored.
    private func normalizedAddress(for device: DeviceDescriptor) -> String? {
        let raw = device.identifier
        guard raw.allSatisfy({ $0.isASCII && ($0.isHexDigit || $0 == ":" || $0 == "-") }) else { return nil }
        let normalized = raw.lowercased().filter(\.isHexDigit)
        return normalized.count == 12 ? normalized : nil
    }

    private static func format(address: String) -> String {
        stride(from: 0, to: min(address.count, 12), by: 2)
            .map { address.dropFirst($0).prefix(2).uppercased() }
            .joined(separator: ":")
    }
}

/// US-QWERTY character → USB HID keycode (usage page 0x07).
enum HIDKeyMap {
    struct Key { var code: UInt8; var shift: Bool }

    static func lookup(_ character: Character) -> Key? {
        if let code = letters[character.lowercased().first ?? character] {
            let shift = character.isUppercase
            return Key(code: code, shift: shift)
        }
        return symbols[character]
    }

    private static let letters: [Character: UInt8] = {
        var map: [Character: UInt8] = [:]
        for (index, letter) in "abcdefghijklmnopqrstuvwxyz".enumerated() {
            map[letter] = UInt8(0x04 + index)
        }
        return map
    }()

    private static let symbols: [Character: Key] = [
        "1": Key(code: 0x1E, shift: false), "!": Key(code: 0x1E, shift: true),
        "2": Key(code: 0x1F, shift: false), "@": Key(code: 0x1F, shift: true),
        "3": Key(code: 0x20, shift: false), "#": Key(code: 0x20, shift: true),
        "4": Key(code: 0x21, shift: false), "$": Key(code: 0x21, shift: true),
        "5": Key(code: 0x22, shift: false), "%": Key(code: 0x22, shift: true),
        "6": Key(code: 0x23, shift: false), "^": Key(code: 0x23, shift: true),
        "7": Key(code: 0x24, shift: false), "&": Key(code: 0x24, shift: true),
        "8": Key(code: 0x25, shift: false), "*": Key(code: 0x25, shift: true),
        "9": Key(code: 0x26, shift: false), "(": Key(code: 0x26, shift: true),
        "0": Key(code: 0x27, shift: false), ")": Key(code: 0x27, shift: true),
        "\n": Key(code: 0x28, shift: false),
        " ": Key(code: 0x2C, shift: false),
        "-": Key(code: 0x2D, shift: false), "_": Key(code: 0x2D, shift: true),
        "=": Key(code: 0x2E, shift: false), "+": Key(code: 0x2E, shift: true),
        "[": Key(code: 0x2F, shift: false), "{": Key(code: 0x2F, shift: true),
        "]": Key(code: 0x30, shift: false), "}": Key(code: 0x30, shift: true),
        "\\": Key(code: 0x31, shift: false), "|": Key(code: 0x31, shift: true),
        ";": Key(code: 0x33, shift: false), ":": Key(code: 0x33, shift: true),
        "'": Key(code: 0x34, shift: false), "\"": Key(code: 0x34, shift: true),
        "`": Key(code: 0x35, shift: false), "~": Key(code: 0x35, shift: true),
        ",": Key(code: 0x36, shift: false), "<": Key(code: 0x36, shift: true),
        ".": Key(code: 0x37, shift: false), ">": Key(code: 0x37, shift: true),
        "/": Key(code: 0x38, shift: false), "?": Key(code: 0x38, shift: true),
    ]
}
