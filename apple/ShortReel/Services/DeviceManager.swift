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
    let phoneRunners = RunnerCoordinator()
    private(set) var connectionErrors: [String: String] = [:]
    private(set) var controlTestStatus: String?
    private(set) var autoLockStatus: String?
    private var autoLockRuns: Set<String> = []
    /// Stage name currently running per device identifier, for status text.
    private(set) var activeStages: [String: String] = [:]
    private var promptSessions: [String: DevicePromptSession] = [:]
    private var pointerTests: Set<String> = []
    /// Injected by the execute-leg supervisor: when it returns a runner client
    /// for a device, that device's input goes over the on-device runner
    /// instead of Bluetooth HID. Lifecycle stays on the transport host.
    @ObservationIgnored var runnerProvider: ((DeviceDescriptor) -> (any PhoneRunnerServing)?)?
    /// Devices the user disconnected by hand stay offline until they connect
    /// them again; every other known bond is re-established automatically.
    private var manualDisconnects: Set<String> = []
    private var reconnectAttempts: [String: Int] = [:]
    @ObservationIgnored private var reconnectTasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var usbWatchTask: Task<Void, Never>?
    private var autoSetupAttempts: [String: Date] = [:]
    @ObservationIgnored private var autoSetupInFlight: Set<String> = []
    @ObservationIgnored private var screenServices: [String: PhoneScreenCaptureService] = [:]
    @ObservationIgnored private var screenOwners: [String: String] = [:]
    @ObservationIgnored private var screenConnectionAttempts: [String: UUID] = [:]
    @ObservationIgnored private var screenConnectionStops: [String: UUID] = [:]
    @ObservationIgnored private var screenRefreshTask: Task<Void, Never>?
    @ObservationIgnored private var screenRefreshRequested = false
    private var disabledScreenAutoConnections: Set<String> = []
    private(set) var screenConnectionErrors: [String: String] = [:]
    private(set) var verifiedScreens: [String: String] = [:]
    var visionProvider: PhoneVisionProvider = .defaultProvider {
        didSet {
            guard visionProvider != oldValue else { return }
            UserDefaults.standard.set(visionProvider.rawValue, forKey: PhoneVisionProvider.preferenceKey)
            for session in promptSessions.values where session.isRunning {
                session.cancel(because: "Stopped because the screen planner changed. Run the request again to use the selected planner.")
            }
            prepareVisionProvider()
        }
    }

    private var visionModels = UserDefaults.standard.dictionary(forKey: PhoneVisionProvider.modelPreferenceKey) as? [String: String] ?? [:]

    var visionModel: String {
        get {
            if let saved = visionModels[visionProvider.rawValue], PhoneVisionProvider.isValidModel(saved) { return saved }
            return visionProvider.defaultModel ?? ""
        }
        set {
            let model = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard visionProvider.defaultModel != nil, PhoneVisionProvider.isValidModel(model), model != visionModel else { return }
            visionModels[visionProvider.rawValue] = model
            UserDefaults.standard.set(visionModels, forKey: PhoneVisionProvider.modelPreferenceKey)
            for session in promptSessions.values where session.isRunning {
                session.cancel(because: "Stopped because the model changed. Run the request again to use the selected model.")
            }
        }
    }

    /// Warms up whatever the selected planner needs (the local UI-TARS
    /// server) so the first request does not pay for it.
    func prepareVisionProvider() {
        if visionProvider == .uiTars { LocalUITarsServer.shared.ensureRunning() }
    }

    var visionUnavailabilityReason: String? {
        switch visionProvider {
        case .uiTars: UITarsPhonePlanner.unavailabilityReason
        case .codex: CodexPhonePlanner.unavailabilityReason
        case .claude: ClaudePhonePlanner.unavailabilityReason
        case .onDevice: PhoneVisionClient.unavailabilityReason
        }
    }

    var isAnyPromptRunning: Bool { promptSessions.values.contains(where: \.isRunning) }

    /// What ShortReel is doing to a phone right now, if anything.
    func activity(for device: Device) -> DeviceActivity? {
        let session = promptSession(for: device)
        if session.isRunning {
            if let workflow = session.entries.last?.workflow { return .stage(workflow.title) }
            return .agent
        }
        if let stage = activeStages[device.identifier] { return .stage(stage) }
        if autoLockRuns.contains(device.identifier) { return .autoLock }
        return nil
    }

    func setActiveStage(_ name: String?, for device: Device) {
        activeStages[device.identifier] = name
    }

    /// Supported model clients, including the current selection.
    var availableVisionProviders: [PhoneVisionProvider] {
        PhoneVisionProvider.allCases.filter { $0 == visionProvider || isVisionProviderInstalled($0) }
    }

    func isVisionProviderInstalled(_ provider: PhoneVisionProvider) -> Bool {
        switch provider {
        case .uiTars: true
        case .codex: CodexPhonePlanner.isInstalled
        case .claude: ClaudePhonePlanner.isInstalled
        case .onDevice: true
        }
    }

    init(container: ModelContainer, bluetoothHost: (any DeviceHost)? = nil, usbHost: (any DeviceHost)? = nil) {
        self.container = container
        self.bluetoothHost = bluetoothHost ?? BluetoothHIDHost()
        self.usbHost = usbHost ?? SimulatedDeviceHost()
        self.runnerProvider = { [weak phoneRunners] descriptor in phoneRunners?.client(for: descriptor.identifier) }
        self.phoneRunners.onAvailabilityChanged = { [weak self] identifier in
            self?.promptSessions.removeValue(forKey: identifier)?.retire(because: "The phone’s input connection changed. Run the request again.")
        }
        self.visionProvider = UserDefaults.standard.string(forKey: PhoneVisionProvider.preferenceKey)
            .flatMap(PhoneVisionProvider.init(rawValue:)) ?? .defaultProvider
        UserDefaults.standard.set(visionProvider.rawValue, forKey: PhoneVisionProvider.preferenceKey)
    }

    private var context: ModelContext { container.mainContext }

    /// Starts listening for host events and re-establishes every known
    /// connection. Connections never survive a relaunch, so stored state is
    /// reset first.
    func start() {
        guard listeners.isEmpty else { return }
        prepareVisionProvider()
        for host in [bluetoothHost, usbHost] {
            let listener = Task { [weak self, host] in
                for await event in host.events {
                    guard let self else { break }
                    self.handle(event)
                }
            }
            listeners.append(listener)
        }

        // An iPhone can reconnect from AssistiveTouch as soon as ShortReel opens,
        // including before the user opens the scan sheet.
        do { try bluetoothHost.prepareForPairing() }
        catch { discovery.errorMessage = error.localizedDescription }

        let devices = allDevices()
        for device in devices {
            device.connectionState = .disconnected
        }
        try? context.save()
        // Re-establish every connection that existed before. USB devices are
        // always eligible; Bluetooth phones only when their bond with this
        // Mac is still in the system pairing list, which filters out legacy
        // demo entries with invented addresses.
        for device in devices where canAutoConnect(device) {
            connect(device)
        }

        usbWatchTask = Task { [weak self] in
            var knownUSBInventory: Set<String> = []
            while !Task.isCancelled {
                guard let self else { return }
                await self.phoneSetup.refresh()
                self.autoConnectUSBPhones()
                var runnerPhones: [String: String] = [:]
                for device in self.allDevices() where device.isLive && !self.manualDisconnects.contains(device.identifier) {
                    let matches = self.phoneSetup.phones.filter { phone in
                        guard phone.trusted else { return false }
                        if device.transport == .usb { return phone.id == device.identifier }
                        guard let address = phone.bluetoothAddress else { return false }
                        return DiscoveredBluetoothDevice.canonicalAddress(address) == DiscoveredBluetoothDevice.canonicalAddress(device.identifier)
                    }
                    if matches.count == 1 { runnerPhones[device.identifier] = matches[0].id }
                }
                await self.phoneRunners.reconcile(runnerPhones)
                let usbInventory = Set(self.phoneSetup.phones.map {
                    "\($0.id)|\($0.trusted)|\($0.bluetoothAddress ?? "")"
                })
                if usbInventory != knownUSBInventory {
                    knownUSBInventory = usbInventory
                    await self.refreshDeviceScreens()
                }
                do { try await Task.sleep(for: .seconds(3)) } catch { return }
            }
        }
    }

    // MARK: - Connections

    func shutdown() async {
        usbWatchTask?.cancel()
        await usbWatchTask?.value
        usbWatchTask = nil
        for session in promptSessions.values { session.cancel(because: "ShortReel is quitting.") }
        LocalUITarsServer.shared.stop()
        await phoneRunners.stopAll()
    }

    func scanForDevices() {
        do {
            try bluetoothHost.prepareForPairing()
            discovery.startScan()
        } catch {
            discovery.errorMessage = error.localizedDescription
        }
    }

    func pair(_ candidate: DiscoveredBluetoothDevice, to persona: Persona?, onPaired: @escaping (Device) -> Void) {
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
            if let persona, persona.isLive { self.bind(device, to: persona) }
            self.connect(device)
            onPaired(device)
        }
    }

    @discardableResult
    func connectUSBPhone(_ phone: ConnectedUSBPhone, to persona: Persona?, onPaired: @escaping (Device) -> Void) -> Task<Void, Never> {
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
                pair(candidate, to: persona, onPaired: onPaired)
            } catch is CancellationError {
                return
            } catch {
                discovery.errorMessage = error.localizedDescription
            }
        }
    }

    private func autoConnectUSBPhones() {
        let phones = phoneSetup.phones
        let present = Set(phones.map(\.id))
        autoSetupAttempts = autoSetupAttempts.filter { present.contains($0.key) }
        autoSetupInFlight.formIntersection(present)
        guard !phones.isEmpty,
              discovery.pairingAddress == nil,
              phoneSetup.preparingIdentifier == nil else { return }
        let registered = allDevices().filter { $0.transport == .bluetoothHID }
        for phone in phones {
            guard phone.trusted, !autoSetupInFlight.contains(phone.id) else { continue }
            if let lastAttempt = autoSetupAttempts[phone.id],
               Date.now.timeIntervalSince(lastAttempt) < 60 { continue }
            if let address = phone.bluetoothAddress,
               let existing = registered.first(where: {
                   DiscoveredBluetoothDevice.canonicalAddress($0.identifier) == DiscoveredBluetoothDevice.canonicalAddress(address)
               }) {
                if existing.isConnected || bluetoothHost.canAutoConnect(existing.descriptor) { continue }
            }
            autoSetupInFlight.insert(phone.id)
            autoSetupAttempts[phone.id] = .now
            let setup = connectUSBPhone(phone, to: nil) { _ in }
            Task { [weak self] in
                await setup.value
                self?.autoSetupInFlight.remove(phone.id)
            }
            break
        }
    }

    private func host(for transport: DeviceTransport) -> any DeviceHost {
        switch transport {
        case .bluetoothHID: bluetoothHost
        case .usb: usbHost
        }
    }

    /// Whether the on-device runner currently supplies input for this device,
    /// so the UI can show which leg is driving.
    func runnerActive(for descriptor: DeviceDescriptor) -> Bool {
        runnerProvider?(descriptor) != nil
    }

    /// The host that performs input for a device: the on-device runner when
    /// the supervisor provides one, otherwise the transport host.
    private func inputHost(for device: Device) -> any DeviceHost {
        if let runner = runnerProvider?(device.descriptor) {
            return RunnerDeviceHost(runner: runner)
        }
        return host(for: device.transport)
    }

    func connect(_ device: Device) {
        guard device.connectionState == .disconnected else { return }
        manualDisconnects.remove(device.identifier)
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
        manualDisconnects.insert(device.identifier)
        reconnectTasks[device.identifier]?.cancel()
        promptSessions[device.identifier]?.cancel(because: "Stopped because the phone was disconnected.")
        connectionErrors[device.identifier] = nil
        host(for: device.transport).disconnect(device.descriptor)
    }

    private func canAutoConnect(_ device: Device) -> Bool {
        device.transport == .usb || host(for: device.transport).canAutoConnect(device.descriptor)
    }

    /// A phone that drops without the user asking for it comes back on its
    /// own: retry with a growing pause, giving up after a few attempts so an
    /// absent phone does not spin forever. It can still reconnect inbound
    /// from AssistiveTouch at any time.
    private func scheduleReconnect(for device: Device) {
        let identifier = device.identifier
        guard device.isLive,
              !manualDisconnects.contains(identifier),
              canAutoConnect(device) else { return }
        let attempt = (reconnectAttempts[identifier] ?? 0) + 1
        guard attempt <= 5 else { return }
        reconnectAttempts[identifier] = attempt
        reconnectTasks[identifier]?.cancel()
        reconnectTasks[identifier] = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(min(30, attempt * 5))) } catch { return }
            guard let self, !Task.isCancelled else { return }
            guard device.isLive,
                  device.connectionState == .disconnected,
                  !self.manualDisconnects.contains(identifier) else { return }
            self.connect(device)
        }
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

    /// Drives Settings › Auto-Lock › Never on the phone itself so it stops
    /// locking its screen. Needs both live channels and the verified USB
    /// screen, since the final tap is chosen by reading the settings page.
    func disableAutoLock(_ device: Device) {
        guard device.isLive, device.transport == .bluetoothHID else { return }
        let descriptor = device.descriptor
        guard !autoLockRuns.contains(descriptor.identifier),
              promptSessions[descriptor.identifier]?.isRunning != true,
              !pointerTests.contains(descriptor.identifier) else {
            autoLockStatus = "Wait for the current device request to finish."
            return
        }
        guard device.isConnected else {
            autoLockStatus = "Connect \(device.name) over Bluetooth first."
            return
        }
        let screen = screenCapture(for: device)
        guard screen.isRunning, let source = screen.selectedSourceID,
              verifiedScreens[descriptor.identifier] == source else {
            autoLockStatus = "Connect \(device.name)’s USB screen before changing Auto-Lock."
            return
        }
        autoLockRuns.insert(descriptor.identifier)
        autoLockStatus = "Setting Auto-Lock to Never on \(device.name)…"
        let host = inputHost(for: device)
        let configurator = PhoneAutoLockConfigurator(
            openSearch: { try await host.pressKey(.search, on: descriptor) },
            type: { try await host.type($0, on: descriptor) },
            confirm: { try await host.pressKey(.enter, on: descriptor) },
            capture: { try await screen.capture(after: $0) },
            recognize: { frame in
                try await Task.detached(priority: .userInitiated) {
                    try PhoneVisionClient.makeScreenContext(frame).targets.map {
                        PhoneHomeTarget(text: $0.text, x: $0.x, y: $0.y)
                    }
                }.value
            },
            tap: { x, y in try await host.tap(.init(x: x, y: y), on: descriptor) },
            blockedReason: { [weak self, weak device] in
                guard let self, let device, device.isLive else { return "This device is no longer available." }
                if !device.isConnected { return "The phone disconnected." }
                if screen.selectedSourceID != source { return "The phone’s screen source changed. Reconnect its USB screen and try again." }
                return nil
            }
        )
        Task {
            defer { autoLockRuns.remove(descriptor.identifier) }
            do {
                try await configurator.disableAutoLock(sourceID: source)
                autoLockStatus = "Auto-Lock is set to Never on \(device.name)."
            } catch {
                autoLockStatus = "Couldn’t disable Auto-Lock on \(device.name): \(error.localizedDescription)"
            }
        }
    }

    func promptSession(for device: Device) -> DevicePromptSession {
        if let session = promptSessions[device.identifier] { return session }
        let descriptor = device.descriptor
        let host = inputHost(for: device)
        let screen = screenCapture(for: device)
        let blockedReason: () -> String? = { [weak self] in
            // Cached sessions outlive the SwiftData instance used to create
            // them. Resolve the current record instead of retaining a weak model.
            guard let self,
                  let device = self.allDevices().first(where: { $0.isLive && $0.identifier == descriptor.identifier })
            else { return "This device is no longer available." }
            if !self.runnerActive(for: descriptor) {
                guard device.transport == .bluetoothHID else { return self.phoneRunners.status(for: descriptor.identifier) }
                guard device.isConnected else { return "Connect this iPhone before running a request." }
            }
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
        let runnerClient = runnerProvider?(descriptor)
        var checking: DevicePromptCheckFactory?
        if let runnerClient {
            let verifier = DevicePromptVerifier(oracle: RunnerOracle(client: runnerClient),
                capture: { try await screen.capture(after: $0) },
                recognizeText: { try DevicePromptVerifier.recognizedText(in: $0) })
            checking = verifier.checkFactory
        }
        let perform: (PhonePromptAction) async throws -> Void = { [weak self] action in
            // The model observes the next frame and chooses any retry itself.
            try await DevicePromptExecutor.perform(action, using: host, on: descriptor,
                checking: self?.visionProvider == .onDevice ? checking : nil)
        }
        let runner = PhoneVisualRunner(capture: { after in
            try await screen.capture(after: after)
        }, decide: { [weak self] goal, frame, history in
            guard let self else { throw PhoneVisionError.unavailable("This device is no longer available.") }
            try Task.checkCancellation()
            switch self.visionProvider {
            case .uiTars:
                return try await UITarsPhonePlanner.nextDecision(goal: goal, frame: frame, history: history)
            case .codex:
                return try await CodexPhonePlanner.nextDecision(goal: goal, frame: frame, history: history, model: self.visionModel)
            case .claude:
                return try await ClaudePhonePlanner.nextDecision(goal: goal, frame: frame, history: history, model: self.visionModel)
            case .onDevice:
                return try await PhoneVisionClient.nextDecision(goal: goal, frame: frame, history: history)
            }
        }, perform: perform, blockedReason: { blockedReason() ?? visualBlockedReason() },
            inspect: { [weak self] frame in
                guard let self else { throw PhoneVisionError.unavailable("This device is no longer available.") }
                switch self.visionProvider {
                case .codex: return try await CodexPhonePlanner.inspectScreen(frame: frame, model: self.visionModel)
                case .claude: return try await ClaudePhonePlanner.inspectScreen(frame: frame, model: self.visionModel)
                case .uiTars, .onDevice: return try await UITarsPhonePlanner.inspectScreen(frame: frame)
                }
            }, prepareCleanupAction: { action, frame in
                try await HomeScreenRemovalGuard.prepare(action, frame: frame)
            })
        let session = DevicePromptSession(deviceName: descriptor.name, deviceIdentifier: descriptor.identifier, blockedReason: blockedReason,
            visualRunner: runner, visualBlockedReason: visualBlockedReason,
            onVisualStart: { [weak self] in
                guard let self, self.visionProvider == .onDevice else { return }
                PhoneVisionClient.prewarm()
            })
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

    func bind(_ device: Device, to persona: Persona) {
        persona.device = device
        persona.deviceName = device.name
        try? context.save()
    }

    func unbind(_ persona: Persona) {
        persona.device = nil
        persona.deviceName = ""
        try? context.save()
    }

    func remove(_ device: Device) {
        manualDisconnects.remove(device.identifier)
        reconnectAttempts[device.identifier] = nil
        reconnectTasks.removeValue(forKey: device.identifier)?.cancel()
        autoLockRuns.remove(device.identifier)
        disabledScreenAutoConnections.remove(device.identifier)
        screenConnectionAttempts[device.identifier] = nil
        screenConnectionStops[device.identifier] = nil
        screenConnectionErrors[device.identifier] = nil
        promptSessions.removeValue(forKey: device.identifier)?.retire(because: "Stopped because the device was removed.")
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
                if !runnerActive(for: device.descriptor) {
                    promptSessions[identifier]?.cancel(because: "Stopped because the phone disconnected.")
                }
                scheduleReconnect(for: device)
            }
            if state == .connected {
                reconnectAttempts[identifier] = 0
                reconnectTasks[identifier]?.cancel()
                manualDisconnects.remove(identifier)
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

enum DeviceActivity: Equatable, Sendable {
    case agent
    case stage(String)
    case autoLock

    var title: String {
        switch self {
        case .agent: "Agent Running"
        case .stage(let name): "Running \(name)"
        case .autoLock: "Setting Auto-Lock"
        }
    }
}
