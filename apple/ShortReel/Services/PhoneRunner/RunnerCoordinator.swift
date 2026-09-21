import Foundation
import Observation

/// Owns one XCTest session and one forwarded port per trusted USB phone.
@Observable @MainActor
final class RunnerCoordinator {
    private(set) var states: [String: RunnerState] = [:]
    @ObservationIgnored private var supervisors: [String: RunnerSupervisor] = [:]
    @ObservationIgnored private var watchers: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var clients: [String: RunnerClient] = [:]
    @ObservationIgnored private var ports: [String: UInt16] = [:]
    @ObservationIgnored private var deviceUDIDs: [String: String] = [:]
    @ObservationIgnored var onAvailabilityChanged: ((String) -> Void)?

    func client(for identifier: String) -> RunnerClient? {
        guard case .ready = states[identifier] else { return nil }
        return clients[identifier]
    }

    func status(for identifier: String) -> String {
        switch states[identifier] {
        case .starting: "Starting iPhone runner…"
        case .ready: "iPhone runner connected"
        case .restarting(let attempt): "Reconnecting iPhone runner (\(attempt))…"
        case .failed(let reason): reason
        case nil: "Connect and trust this iPhone over USB."
        }
    }

    func reconcile(_ devices: [String: String]) async {
        for identifier in Array(deviceUDIDs.keys) where devices[identifier] != deviceUDIDs[identifier] {
            await stop(identifier)
        }
        for (identifier, udid) in devices where deviceUDIDs[identifier] == nil {
            deviceUDIDs[identifier] = udid
            states[identifier] = .starting
            watchers[identifier] = Task { [weak self] in
                guard let self else { return }
                do {
                    let processes = SystemProcessRunner()
                    let mode = try await processes.runChecked(.init(executable: "ios", arguments: ["devmode", "get", "--udid", udid]))
                    let enabled = (try? JSONSerialization.jsonObject(with: Data(mode.stdout.utf8))) as? [String: Bool]
                    guard enabled?["DeveloperModeEnabled"] == true else {
                        throw SetupError("Enable Developer Mode in this iPhone’s Privacy & Security settings, restart, and confirm Enable. Then retry the runner.")
                    }
                    guard let resources = Bundle.main.resourceURL else { throw SetupError("Runner resources are missing.") }
                    let folder = resources.appending(path: "PhoneRunner")
                    let app = folder.appending(path: "ShortReelRunner.app")
                    let tests = folder.appending(path: "ShortReelRunnerUITests-Runner.app")
                    for product in [app, tests] {
                        guard FileManager.default.fileExists(atPath: product.appending(path: "embedded.mobileprovision").path) else {
                            throw SetupError("Signed iPhone runner is missing. Run bun scripts/runner.ts with SHORTREEL_DEVELOPMENT_TEAM set, then rebuild ShortReel.")
                        }
                    }
                    try Task.checkCancellation()
                    let used = Set(self.ports.values)
                    guard let port = (UInt16(18700)...UInt16(18800)).first(where: { !used.contains($0) }) else {
                        throw SetupError("No free runner ports.")
                    }
                    self.ports[identifier] = port
                    var configuration = RunnerSupervisor.Configuration(udid: udid)
                    configuration.localPort = port
                    configuration.runnerProductPath = app
                    configuration.uitestRunnerProductPath = tests
                    let supervisor = RunnerSupervisor(configuration: configuration)
                    self.supervisors[identifier] = supervisor
                    self.clients[identifier] = RunnerClient(port: port)
                    await supervisor.start()
                    for await state in supervisor.states {
                        guard !Task.isCancelled else { break }
                        let wasReady = self.client(for: identifier) != nil
                        self.states[identifier] = state
                        if wasReady != (self.client(for: identifier) != nil) {
                            self.onAvailabilityChanged?(identifier)
                        }
                    }
                } catch is CancellationError {
                } catch {
                    self.states[identifier] = .failed(reason: error.localizedDescription)
                }
            }
        }
    }

    func retry(_ identifier: String) async {
        guard let udid = deviceUDIDs[identifier] else { return }
        var devices = deviceUDIDs
        await stop(identifier)
        devices[identifier] = udid
        await reconcile(devices)
    }

    func stopAll() async {
        for identifier in Array(deviceUDIDs.keys) { await stop(identifier) }
        await GoIosTunnelDaemon.shared.stop()
    }

    private func stop(_ identifier: String) async {
        watchers[identifier]?.cancel()
        // Await preparation too, so it cannot publish a supervisor after stop.
        if let supervisor = supervisors[identifier] { await supervisor.stop() }
        await watchers.removeValue(forKey: identifier)?.value
        if let supervisor = supervisors.removeValue(forKey: identifier) { await supervisor.stop() }
        let wasReady = client(for: identifier) != nil
        clients[identifier] = nil
        ports[identifier] = nil
        deviceUDIDs[identifier] = nil
        states[identifier] = nil
        if wasReady { onAvailabilityChanged?(identifier) }
    }

    private struct SetupError: LocalizedError {
        var errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }
}
