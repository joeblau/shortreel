import Foundation
@preconcurrency import CoreBluetooth
@preconcurrency import IOBluetooth
import Observation
import OSLog

struct DiscoveredBluetoothDevice: Identifiable, Equatable {
    let id: String
    var name: String
    var isPaired: Bool
    var isNearby: Bool

    static func canonicalAddress(_ address: String) -> String {
        address.replacingOccurrences(of: "-", with: ":").uppercased()
    }
}

/// Classic Bluetooth discovery and bonding. A successful bond is separate
/// from the HID channels that BluetoothHIDHost uses to control the phone.
/// Discovery and pairing callbacks are marshalled onto the main run loop.
@Observable
@MainActor
final class BluetoothDiscovery: NSObject, @preconcurrency IOBluetoothDevicePairDelegate, @preconcurrency CBCentralManagerDelegate {
    private(set) var devices: [DiscoveredBluetoothDevice] = []
    private(set) var isScanning = false
    private(set) var pairingAddress: String?
    private(set) var confirmationCode: String?
    private(set) var displayedPasskey: String?
    private(set) var needsPIN = false
    private(set) var status = ""
    var errorMessage: String?

    @ObservationIgnored private var inquiry: CBClassicDiscovery?
    @ObservationIgnored private var scanGeneration = UUID()
    @ObservationIgnored private var pairer: IOBluetoothDevicePair?
    @ObservationIgnored private var selectedDevice: DiscoveredBluetoothDevice?
    @ObservationIgnored private var onPaired: ((DiscoveredBluetoothDevice) -> Void)?
    @ObservationIgnored private var timeout: Task<Void, Never>?
    @ObservationIgnored private var permissionManager: CBCentralManager?
    @ObservationIgnored private var awaitingBluetooth = false
    private let log = Logger(subsystem: "com.joeblau.engage", category: "BluetoothDiscovery")

    func startScan() {
        guard !isScanning, pairingAddress == nil else { return }
        errorMessage = nil
        isScanning = true
        awaitingBluetooth = true
        status = "Waiting for Bluetooth…"
        if let permissionManager {
            centralManagerDidUpdateState(permissionManager)
        } else {
            permissionManager = CBCentralManager(delegate: self, queue: .main)
        }
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        guard awaitingBluetooth else { return }
        switch central.state {
        case .poweredOn:
            awaitingBluetooth = false
            beginInquiry()
        case .unauthorized:
            fail("Allow Engage to use Bluetooth in System Settings › Privacy & Security › Bluetooth.")
        case .poweredOff:
            fail("Turn on Bluetooth on this Mac, then scan again.")
        case .unsupported:
            fail("Bluetooth discovery is unavailable on this Mac.")
        default: break
        }
    }

    private func beginInquiry() {
        devices = []
        for case let device as IOBluetoothDevice in IOBluetoothDevice.pairedDevices() ?? [] {
            update(device, nearby: false)
        }
        let scanner = CBClassicDiscovery()
        let generation = UUID()
        scanGeneration = generation
        scanner.onDeviceFound = { [weak self] address, name in
            Task { @MainActor in
                guard let self, self.scanGeneration == generation, self.isScanning else { return }
                self.update(address: address, name: name)
            }
        }
        scanner.onFinished = { [weak self] in
            Task { @MainActor in
                guard let self, self.scanGeneration == generation else { return }
                self.inquiry = nil
                self.isScanning = false
                if self.pairingAddress != nil { self.beginPairing() }
                else { self.stopScan() }
            }
        }
        scanner.onError = { [weak self] message in
            Task { @MainActor in
                guard let self, self.scanGeneration == generation else { return }
                self.fail(message)
            }
        }
        inquiry = scanner
        isScanning = true
        status = "Searching for nearby devices…"
        scanner.start()
        log.info("Started Classic Bluetooth inquiry")
        timeout = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(30)) } catch { return }
            self?.stopScan()
        }
    }

    func stopScan() {
        awaitingBluetooth = false
        timeout?.cancel()
        timeout = nil
        let scanner = inquiry
        inquiry = nil
        scanGeneration = UUID()
        scanner?.onFinished = nil
        scanner?.onError = nil
        scanner?.onDeviceFound = nil
        scanner?.stop()
        isScanning = false
        status = devices.contains(where: \.isNearby) ? "Select your device to pair." : "No nearby devices found. Try scanning again."
    }

    func pair(_ device: DiscoveredBluetoothDevice, onPaired: @escaping (DiscoveredBluetoothDevice) -> Void) {
        guard pairingAddress == nil else { return }
        errorMessage = nil
        selectedDevice = device
        pairingAddress = device.id
        self.onPaired = onPaired
        status = "Connecting to \(device.name)…"
        timeout?.cancel()
        timeout = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(90)) } catch { return }
            self?.fail("Pairing timed out. Keep the phone’s Bluetooth settings open and try again.")
        }
        if let inquiry, isScanning {
            // The SDK requires inquiry to finish before starting a connection.
            inquiry.stop()
        } else {
            beginPairing()
        }
    }

    func confirmPairing(_ matches: Bool) {
        guard confirmationCode != nil else { return }
        confirmationCode = nil
        pairer?.replyUserConfirmation(matches)
        if !matches { cancelPairing() }
    }

    func submitPIN(_ pin: String) {
        let bytes = Array(pin.utf8)
        guard needsPIN, !bytes.isEmpty, bytes.count <= 16 else { return }
        var code = BluetoothPINCode()
        withUnsafeMutableBytes(of: &code) { $0.copyBytes(from: bytes) }
        needsPIN = false
        pairer?.replyPINCode(bytes.count, pinCode: &code)
    }

    func cancelPairing() {
        timeout?.cancel()
        timeout = nil
        pairer?.delegate = nil
        pairer?.stop()
        pairer = nil
        pairingAddress = nil
        selectedDevice = nil
        onPaired = nil
        confirmationCode = nil
        displayedPasskey = nil
        needsPIN = false
    }

    private func beginPairing() {
        guard let selectedDevice,
              let device = IOBluetoothDevice(addressString: selectedDevice.id) else {
            fail("This device is no longer available. Scan again.")
            return
        }
        if device.isPaired() {
            finishPairing()
            return
        }
        pairer = IOBluetoothDevicePair(device: device)
        guard let pairer else {
            fail("Couldn’t create a pairing request for this device.")
            return
        }
        pairer.delegate = self
        let result = pairer.start()
        if result != kIOReturnSuccess { fail("Couldn’t start pairing (\(result)).") }
    }

    private func finishPairing() {
        guard var device = selectedDevice else { return }
        device.isPaired = true
        if let index = devices.firstIndex(where: { $0.id == device.id }) { devices[index] = device }
        let completion = onPaired
        // Do not call stop() on success: it would disconnect the new bond.
        pairer?.delegate = nil
        pairer = nil
        cancelPairing()
        status = "Bluetooth paired. Waiting for the phone’s controller connection…"
        completion?(device)
    }

    private func fail(_ message: String) {
        cancelPairing()
        stopScan()
        errorMessage = message
        log.error("\(message, privacy: .public)")
    }

    private func update(_ device: IOBluetoothDevice, nearby: Bool) {
        guard let address = device.addressString else { return }
        let id = DiscoveredBluetoothDevice.canonicalAddress(address)
        let previous = devices.first(where: { $0.id == id })
        let item = DiscoveredBluetoothDevice(id: id, name: device.name ?? previous?.name ?? "Unnamed device",
                                            isPaired: device.isPaired(), isNearby: nearby || previous?.isNearby == true)
        if let index = devices.firstIndex(where: { $0.id == id }) { devices[index] = item }
        else { devices.append(item) }
        devices.sort {
            if $0.isNearby != $1.isNearby { return $0.isNearby }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    private func update(address: String, name: String) {
        let id = DiscoveredBluetoothDevice.canonicalAddress(address)
        let paired = IOBluetoothDevice(addressString: id)?.isPaired() ?? false
        let item = DiscoveredBluetoothDevice(id: id, name: name, isPaired: paired, isNearby: true)
        if let index = devices.firstIndex(where: { $0.id == id }) { devices[index] = item }
        else { devices.append(item) }
        devices.sort {
            if $0.isNearby != $1.isNearby { return $0.isNearby }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
        log.info("Received nearby Classic Bluetooth device")
    }

    func devicePairingUserConfirmationRequest(_ sender: Any!, numericValue: BluetoothNumericValue) {
        guard let sender = sender as? IOBluetoothDevicePair, sender === pairer else { return }
        confirmationCode = String(format: "%06u", numericValue)
        status = "Confirm that the code matches the one on your phone."
    }

    func devicePairingUserPasskeyNotification(_ sender: Any!, passkey: BluetoothPasskey) {
        guard let sender = sender as? IOBluetoothDevicePair, sender === pairer else { return }
        displayedPasskey = String(format: "%06u", passkey)
        status = "Enter this code on your phone."
    }

    func devicePairingPINCodeRequest(_ sender: Any!) {
        guard let sender = sender as? IOBluetoothDevicePair, sender === pairer else { return }
        needsPIN = true
        status = "Enter the PIN shown on your device."
    }

    func devicePairingFinished(_ sender: Any!, error: IOReturn) {
        guard let sender = sender as? IOBluetoothDevicePair, sender === pairer else { return }
        if error == kIOReturnSuccess { finishPairing() }
        else { fail("Pairing failed (\(error)). Keep the phone’s Bluetooth settings open, then try again.") }
    }
}
