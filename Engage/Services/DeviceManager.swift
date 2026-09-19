import Foundation
import Observation
import SwiftData

/// Owns the registry of phones and keeps their SwiftData connection state in
/// sync with the underlying `DeviceHost`.
@Observable
@MainActor
final class DeviceManager {
    private let container: ModelContainer
    private let bluetoothHost: any DeviceHost
    private let usbHost: any DeviceHost
    private var listeners: [Task<Void, Never>] = []
    let discovery = BluetoothDiscovery()
    let phoneSetup = USBPhoneSetup()
    private(set) var connectionErrors: [String: String] = [:]
    private(set) var controlTestStatus: String?
    @ObservationIgnored private var promptSessions: [String: DevicePromptSession] = [:]
    private var pointerTests: Set<String> = []
    @ObservationIgnored private var screenServices: [String: PhoneScreenCaptureService] = [:]
    @ObservationIgnored private var screenOwners: [String: String] = [:]
    @ObservationIgnored private var screenConnectionAttempts: [String: UUID] = [:]
    @ObservationIgnored private var screenConnectionStops: [String: UUID] = [:]
    @ObservationIgnored private var screenRefreshTask: Task<Void, Never>?
    @ObservationIgnored private var screenRefreshRequested = false
    private var disabledScreenAutoConnections: Set<String> = []
    private(set) var screenConnectionErrors: [String: String] = [:]
    private(set) var verifiedScreens: [String: String] = [:]
    var visionProvider: PhoneVisionProvider = .onDevice {
        didSet {
            guard visionProvider != oldValue else { return }
            UserDefaults.standard.set(visionProvider.rawValue, forKey: PhoneVisionProvider.preferenceKey)
            for session in promptSessions.values where session.isRunning {
                session.cancel(because: "Stopped because the screen planner changed. Run the request again to use the selected planner.")
            }
        }
    }

    var visionUnavailabilityReason: String? {
        switch visionProvider {
        case .onDevice: PhoneVisionClient.unavailabilityReason
        case .grok: GrokPhonePlanner.unavailabilityReason
        }
    }

    var isAnyPromptRunning: Bool { promptSessions.values.contains(where: \.isRunning) }

    init(container: ModelContainer, bluetoothHost: (any DeviceHost)? = nil, usbHost: (any DeviceHost)? = nil) {
        self.container = container
        self.bluetoothHost = bluetoothHost ?? BluetoothHIDHost()
        self.usbHost = usbHost ?? SimulatedDeviceHost()
        self.visionProvider = UserDefaults.standard.string(forKey: PhoneVisionProvider.preferenceKey)
            .flatMap(PhoneVisionProvider.init(rawValue:)) ?? .onDevice
    }

    private var context: ModelContext { container.mainContext }

    /// Starts listening for host events and re-establishes every known
    /// connection. Connections never survive a relaunch, so stored state is
    /// reset first.
    func start() {
        guard listeners.isEmpty else { return }
        for host in [bluetoothHost, usbHost] {
            let listener = Task { [weak self, host] in
                for await event in host.events {
                    guard let self else { break }
                    self.handle(event)
                }
            }
            listeners.append(listener)
        }

        // An iPhone can reconnect from AssistiveTouch as soon as Engage opens,
        // including before the user opens the scan sheet.
        do { try bluetoothHost.prepareForPairing() }
        catch { discovery.errorMessage = error.localizedDescription }

        let devices = allDevices()
        for device in devices {
            device.connectionState = .disconnected
        }
        try? context.save()
        // Bluetooth connections are initiated from a discovered selection;
        // legacy demo entries may contain invented Bluetooth addresses.
        for device in devices where device.transport == .usb {
            connect(device)
        }
    }

    // MARK: - Connections

    func scanForDevices() {
        do {
            try bluetoothHost.prepareForPairing()
            discovery.startScan()
        } catch {
            discovery.errorMessage = error.localizedDescription
        }
    }

    func pair(_ candidate: DiscoveredBluetoothDevice, to account: Account?, onPaired: @escaping (Device) -> Void) {
        do {
            try bluetoothHost.prepareForPairing()
        } catch {
            discovery.errorMessage = error.localizedDescription
            return
        }
        discovery.pair(candidate) { [weak self] paired in
            guard let self else { return }
            let existing = self.allDevices().first {
                $0.transport == .bluetoothHID && DiscoveredBluetoothDevice.canonicalAddress($0.identifier) == paired.id
            }
            let device = existing ?? Device(name: paired.name, modelName: "Bluetooth device", transport: .bluetoothHID, identifier: paired.id)
            device.name = paired.name
            if existing == nil { self.context.insert(device) }
            do {
                try self.context.save()
            } catch {
                if existing == nil { self.context.delete(device) }
                self.discovery.errorMessage = "Paired, but couldn’t save the device: \(error.localizedDescription)"
                return
            }
            if let account, account.isLive { self.bind(device, to: account) }
            self.connect(device)
            onPaired(device)
        }
    }

    @discardableResult
    func connectUSBPhone(_ phone: ConnectedUSBPhone, to account: Account?, onPaired: @escaping (Device) -> Void) -> Task<Void, Never> {
        Task {
            do {
                let prepared = try await phoneSetup.prepare(phone)
                try Task.checkCancellation()
                guard let address = prepared.bluetoothAddress else {
                    discovery.errorMessage = "The phone did not provide its Bluetooth address. Reconnect the cable and try again."
                    return
                }
                // The real address comes from this trusted phone; nothing is
                // inferred from a similar name or a previously saved entry.
                let candidate = DiscoveredBluetoothDevice(id: DiscoveredBluetoothDevice.canonicalAddress(address),
                    name: prepared.name, isPaired: false, isNearby: true)
                pair(candidate, to: account, onPaired: onPaired)
            } catch is CancellationError {
                return
            } catch {
                discovery.errorMessage = error.localizedDescription
            }
        }
    }

    private func host(for transport: DeviceTransport) -> any DeviceHost {
        switch transport {
        case .bluetoothHID: bluetoothHost
        case .usb: usbHost
        }
    }

    func connect(_ device: Device) {
        guard device.connectionState == .disconnected else { return }
        connectionErrors[device.identifier] = nil
        device.connectionState = .pairing
        let descriptor = device.descriptor
        let host = host(for: device.transport)
        Task {
            do {
                try await host.connect(descriptor)
            } catch {
                connectionErrors[descriptor.identifier] = error.localizedDescription
                handle(.connectionChanged(identifier: descriptor.identifier, state: .disconnected))
            }
        }
    }

    func disconnect(_ device: Device) {
        promptSessions[device.identifier]?.cancel(because: "Stopped because the phone was disconnected.")
        connectionErrors[device.identifier] = nil
        host(for: device.transport).disconnect(device.descriptor)
    }

    func testControl(_ device: Device) {
        guard let host = bluetoothHost as? BluetoothHIDHost, device.transport == .bluetoothHID else { return }
        let descriptor = device.descriptor
        guard !pointerTests.contains(descriptor.identifier), promptSessions[descriptor.identifier]?.isRunning != true else {
            controlTestStatus = "Wait for the current device request to finish."
            return
        }
        pointerTests.insert(descriptor.identifier)
        controlTestStatus = "Moving the pointer on \(device.name)…"
        Task {
            defer { pointerTests.remove(descriptor.identifier) }
            do {
                try await host.testPointer(on: descriptor)
                controlTestStatus = "Pointer test sent to \(descriptor.name). Check that the pointer moved on the iPhone."
            } catch {
                controlTestStatus = "Pointer test failed: \(error.localizedDescription)"
                connectionErrors[descriptor.identifier] = error.localizedDescription
            }
        }
    }

    func promptSession(for device: Device) -> DevicePromptSession {
        if let session = promptSessions[device.identifier] { return session }
        let descriptor = device.descriptor
        let host = bluetoothHost
        let screen = screenCapture(for: device)
        let blockedReason: () -> String? = { [weak self, weak device] in
            guard let self, let device, device.isLive else { return "This device is no longer available." }
            guard device.transport == .bluetoothHID else { return "Connect this iPhone over Bluetooth to run a request." }
            guard device.isConnected else { return "Connect this iPhone before running a request." }
            guard !self.pointerTests.contains(descriptor.identifier) else { return "Wait for the pointer test to finish, then try again." }
            return nil
        }
        let screenBlockedReason: () -> String? = { [weak self] in
            guard let self else { return "This device is no longer available." }
            guard screen.isRunning else { return "Connect this iPhone’s USB screen for requests that need to see the phone." }
            guard let source = screen.selectedSourceID, self.verifiedScreens[descriptor.identifier] == source else {
                return "Connect the USB screen belonging to this iPhone before running a request."
            }
            return nil
        }
        let visualBlockedReason: () -> String? = { [weak self] in
            guard let self else { return "This device is no longer available." }
            return self.visionUnavailabilityReason ?? screenBlockedReason()
        }
        let perform: (PhonePromptAction) async throws -> Void = { action in
            if case .home = action, screenBlockedReason() == nil, let source = screen.selectedSourceID {
                let navigator = PhoneHomeNavigator(openMenu: {
                    try await host.openAssistiveTouchMenu(on: descriptor)
                }, capture: { try await screen.capture(after: $0) }, recognize: { frame in
                    try await Task.detached(priority: .userInitiated) {
                        try PhoneVisionClient.makeScreenContext(frame.jpegData).targets.map {
                            PhoneHomeTarget(text: $0.text, x: $0.x, y: $0.y)
                        }
                    }.value
                }, tap: { x, y in
                    try await host.tap(.init(x: x, y: y), on: descriptor)
                }, blockedReason: {
                    if screen.selectedSourceID != source { return "The phone’s screen source changed. Reconnect its USB screen and try again." }
                    return blockedReason() ?? screenBlockedReason()
                })
                try await navigator.goHome(sourceID: source)
                return
            }
            try await DevicePromptExecutor.perform(action, using: host, on: descriptor)
        }
        let runner = PhoneVisualRunner(capture: { after in
            try await screen.capture(after: after)
        }, decide: { [weak self] goal, frame, history in
            guard let self else { throw PhoneVisionError.unavailable("This device is no longer available.") }
            try Task.checkCancellation()
            switch self.visionProvider {
            case .onDevice:
                return try await PhoneVisionClient.nextDecision(goal: goal, frame: frame, history: history)
            case .grok:
                return try await GrokPhonePlanner.nextDecision(goal: goal, frame: frame, history: history)
            }
        }, perform: perform, blockedReason: { blockedReason() ?? visualBlockedReason() })
        let session = DevicePromptSession(deviceName: descriptor.name, blockedReason: blockedReason,
            planner: { prompt in
                do { return try DevicePromptPlanner.plan(prompt) }
                catch {
                    guard OnDevicePromptPlanner.unavailabilityReason == nil else { throw error }
                    return try await OnDevicePromptPlanner.plan(prompt)
                }
            }, perform: perform, visualRunner: runner, visualBlockedReason: visualBlockedReason)
        promptSessions[descriptor.identifier] = session
        return session
    }

    func screenCapture(for device: Device) -> PhoneScreenCaptureService {
        if let service = screenServices[device.identifier] { return service }
        let service = PhoneScreenCaptureService()
        screenServices[device.identifier] = service
        return service
    }

    func refreshScreenSources(for device: Device) async throws {
        guard device.isLive else { throw CancellationError() }
        let screen = screenCapture(for: device)
        await phoneSetup.refresh()
        try Task.checkCancellation()
        guard device.isLive else { throw CancellationError() }
        try await screen.refresh()
    }

    private var screenPhoneIdentities: [PhoneScreenPhoneIdentity] {
        phoneSetup.phones.map { PhoneScreenPhoneIdentity(id: $0.id, name: $0.name,
            bluetoothAddress: $0.bluetoothAddress, trusted: $0.trusted) }
    }

    /// Prefer hardware IDs. Privacy UUIDs need an unambiguous USB inventory;
    /// matching a display name alone is insufficient.
    func matchingScreenSource(for device: Device) -> String? {
        guard device.isLive else { return nil }
        return PhoneScreenAssociation.matchingSource(bluetoothAddress: device.identifier,
            phones: screenPhoneIdentities, sources: screenCapture(for: device).sources)
    }

    func isScreenAutoConnectDisabled(for device: Device) -> Bool {
        disabledScreenAutoConnections.contains(device.identifier)
    }

    /// All gallery callers share one pass. USB inventory refreshes are ordered
    /// because USBPhoneSetup deliberately ignores overlapping discovery calls.
    /// A trusted USB screen remains useful while Bluetooth input is disconnected.
    func refreshDeviceScreens() async {
        if let screenRefreshTask {
            screenRefreshRequested = true
            await screenRefreshTask.value
            return
        }
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            repeat {
                self.screenRefreshRequested = false
                await self.refreshDeviceScreensPass()
            } while self.screenRefreshRequested
            // Clear before the shared task completes. A new caller must not
            // join an already-finished task and lose its requested refresh.
            self.screenRefreshTask = nil
        }
        screenRefreshTask = task
        await task.value
    }

    private func refreshDeviceScreensPass() async {
        let devices = allDevices().filter(\.isLive)
        var refreshedDevices: [(device: Device, identifier: String)] = []
        for device in devices {
            guard device.isLive else { continue }
            let identifier = device.identifier
            do {
                try await refreshScreenSources(for: device)
                guard device.isLive, device.identifier == identifier else { continue }
                refreshedDevices.append((device, identifier))
            } catch is CancellationError {
                // A removed device must not become a refresh error.
            } catch {
                guard device.isLive, device.identifier == identifier else { continue }
                screenConnectionErrors[identifier] = error.localizedDescription
            }
        }
        for (device, identifier) in refreshedDevices {
            guard device.isLive, device.identifier == identifier else { continue }
            do {
                let screen = screenCapture(for: device)
                if screen.isRunning {
                    screenConnectionErrors[identifier] = nil
                    continue
                }
                guard screen.authorizationStatus == .authorized,
                      !screen.isStarting,
                      !isScreenAutoConnectDisabled(for: device),
                      screenConnectionAttempts[identifier] == nil,
                      screenConnectionStops[identifier] == nil,
                      promptSessions[identifier]?.isRunning != true,
                      let sourceID = matchingScreenSource(for: device) else { continue }
                try await connectScreen(for: device, sourceID: sourceID, automatically: true)
            } catch is CancellationError {
                // A removed device or explicit stop must not become an error.
            } catch {
                guard device.isLive, device.identifier == identifier,
                      !isScreenAutoConnectDisabled(for: device) else { continue }
                screenConnectionErrors[identifier] = error.localizedDescription
            }
        }
    }

    func connectScreen(for device: Device, sourceID: String, automatically: Bool = false) async throws {
        guard device.isLive else { throw PhoneVisionError.unavailable("This device is no longer available.") }
        let identifier = device.identifier
        if automatically, disabledScreenAutoConnections.contains(identifier) { return }
        let service = screenCapture(for: device)
        guard screenConnectionAttempts[identifier] == nil,
              screenConnectionStops[identifier] == nil, !service.isStarting else {
            let error = PhoneVisionError.unavailable("Wait for the current screen connection to finish.")
            screenConnectionErrors[identifier] = error.localizedDescription
            throw error
        }
        if !automatically {
            disabledScreenAutoConnections.remove(identifier)
            screenConnectionErrors[identifier] = nil
        }
        guard promptSessions[identifier]?.isRunning != true else {
            let error = PhoneVisionError.unavailable("Stop the current request before changing its screen.")
            screenConnectionErrors[identifier] = error.localizedDescription
            throw error
        }
        let attempt = UUID()
        screenConnectionAttempts[identifier] = attempt
        defer {
            if screenConnectionAttempts[identifier] == attempt {
                screenConnectionAttempts[identifier] = nil
            }
        }
        var startedCapture = false
        do {
            await phoneSetup.refresh()
            try Task.checkCancellation()
            guard device.isLive, device.identifier == identifier,
                  screenConnectionAttempts[identifier] == attempt,
                  !disabledScreenAutoConnections.contains(identifier) else { throw CancellationError() }
            guard PhoneScreenAssociation.selectedPhone(bluetoothAddress: identifier, phones: screenPhoneIdentities) != nil,
                  service.sources.contains(where: { $0.id == sourceID }) else {
                throw PhoneVisionError.unavailable("Couldn’t identify the trusted USB phone for \(device.name). Unlock it, confirm Trust, and refresh.")
            }
            let automaticMatch = matchingScreenSource(for: device)
            guard !automatically || automaticMatch == sourceID else {
                throw PhoneVisionError.unavailable("Choose this phone’s screen in the screen picker before connecting it.")
            }
            if let automaticMatch, automaticMatch != sourceID {
                throw PhoneVisionError.unavailable("That screen belongs to a different phone. Select the screen for \(device.name).")
            }
            if let owner = screenOwners[sourceID], owner != identifier {
                throw PhoneVisionError.unavailable("This screen is already connected to another device session.")
            }
            screenOwners[sourceID] = identifier
            startedCapture = true
            try await service.start(sourceID: sourceID)
            try Task.checkCancellation()
            guard device.isLive, device.identifier == identifier,
                  screenConnectionAttempts[identifier] == attempt,
                  !disabledScreenAutoConnections.contains(identifier) else { throw CancellationError() }
            screenOwners = screenOwners.filter { $0.value != identifier || $0.key == sourceID }
            verifiedScreens[identifier] = sourceID
            screenConnectionErrors[identifier] = nil
        } catch {
            // A stop/removal can invalidate this attempt during any await. Its
            // cleanup must never stop or release a subsequent capture attempt.
            guard screenConnectionAttempts[identifier] == attempt else { throw CancellationError() }
            if !(error is CancellationError) {
                screenConnectionErrors[identifier] = error.localizedDescription
            }
            if startedCapture {
                verifiedScreens[identifier] = nil
                await service.stop()
                if screenConnectionAttempts[identifier] == attempt {
                    screenOwners = screenOwners.filter { $0.value != identifier }
                }
            }
            throw error
        }
    }

    func stopScreen(for device: Device) async {
        guard device.isLive else { return }
        let identifier = device.identifier
        disabledScreenAutoConnections.insert(identifier)
        screenConnectionAttempts[identifier] = nil
        let stop = UUID()
        screenConnectionStops[identifier] = stop
        promptSessions[identifier]?.cancel(because: "Stopped because screen capture was disconnected.")
        verifiedScreens[identifier] = nil
        await screenServices[identifier]?.stop()
        if screenConnectionStops[identifier] == stop {
            screenOwners = screenOwners.filter { $0.value != identifier }
            screenConnectionStops[identifier] = nil
        }
    }

    // MARK: - Registry

    func bind(_ device: Device, to account: Account) {
        account.device = device
        account.deviceName = device.name
        try? context.save()
    }

    func unbind(_ account: Account) {
        account.device = nil
        try? context.save()
    }

    func remove(_ device: Device) {
        disabledScreenAutoConnections.remove(device.identifier)
        screenConnectionAttempts[device.identifier] = nil
        screenConnectionStops[device.identifier] = nil
        screenConnectionErrors[device.identifier] = nil
        promptSessions.removeValue(forKey: device.identifier)?.cancel(because: "Stopped because the device was removed.")
        if let screen = screenServices.removeValue(forKey: device.identifier) {
            Task { await screen.stop() }
        }
        verifiedScreens[device.identifier] = nil
        screenOwners = screenOwners.filter { $0.value != device.identifier }
        host(for: device.transport).disconnect(device.descriptor)
        context.delete(device)
        try? context.save()
    }

    // MARK: - Private

    private func handle(_ event: DeviceHostEvent) {
        switch event {
        case .discovered(let descriptor):
            if allDevices().contains(where: { $0.identifier == descriptor.identifier }) { return }
            let device = Device(name: descriptor.name, modelName: "Bluetooth device",
                transport: descriptor.transport, identifier: descriptor.identifier)
            context.insert(device)
            try? context.save()
        case .connectionChanged(let identifier, let state):
            guard let device = allDevices().first(where: { $0.identifier == identifier }) else { return }
            device.connectionState = state
            if state == .disconnected {
                promptSessions[identifier]?.cancel(because: "Stopped because the phone disconnected.")
            }
            if state == .connected {
                connectionErrors[identifier] = nil
                device.lastSeen = .now
            }
            try? context.save()
        case .addressLearned(let identifier, let address):
            guard let device = allDevices().first(where: { $0.identifier == identifier }) else { return }
            device.identifier = address
            try? context.save()
        }
    }

    private func allDevices() -> [Device] {
        (try? context.fetch(FetchDescriptor<Device>())) ?? []
    }
}
