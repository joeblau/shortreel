import Foundation

struct RunnerOracle: Sendable {
    enum Answer<Value: Sendable>: Sendable {
        case value(Value)
        case unavailable
        case failed(String)

        var value: Value? {
            if case .value(let value) = self { return value }
            return nil
        }
    }

    enum ForegroundCheck: Sendable, Equatable {
        case foreground(observed: String)
        case mismatch(observed: String)
        case indeterminate(String)
    }

    static let springboardBundleID = "com.apple.springboard"

    let client: (any PhoneRunnerServing)?

    init(client: (any PhoneRunnerServing)? = nil) {
        self.client = client
    }

    func isAppForeground(bundleID: String) async -> Answer<ForegroundCheck> {
        await query { client in
            let state = try await client.appState(target: .foreground)
            if let observed = state.bundleID, Self.refersToSameApp(observed, bundleID) {
                switch state.state {
                case .foreground:
                    return .foreground(observed: observed)
                case .background, .notRunning:
                    return .mismatch(observed: observed)
                case .unknown:
                    return .indeterminate("\(observed) was last observed, but its state is unknown.")
                }
            }
            if let observed = state.bundleID {
                return .mismatch(observed: observed)
            }
            if state.springboardForeground {
                return Self.refersToSameApp(Self.springboardBundleID, bundleID)
                    ? .foreground(observed: Self.springboardBundleID)
                    : .mismatch(observed: Self.springboardBundleID)
            }
            return .indeterminate("The runner has not observed which app is in the foreground.")
        }
    }

    func springboardAlerts() async -> Answer<[AlertInfo]> {
        await query { try await $0.alerts(target: .springboard).alerts }
    }

    func isLocked() async -> Answer<Bool> {
        await query { try await $0.locked().locked }
    }

    func treeText(target: RunnerTarget = .foreground, maxDepth: Int? = 8) async -> Answer<String> {
        await query { try await $0.tree(target: target, maxDepth: maxDepth).tree }
    }

    static func refersToSameApp(_ observed: String, _ query: String) -> Bool {
        guard !observed.isEmpty, !query.isEmpty else { return false }
        return observed.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil
            || query.range(of: observed, options: [.caseInsensitive, .diacriticInsensitive]) != nil
    }

    private func query<Value: Sendable>(_ body: (any PhoneRunnerServing) async throws -> Value) async -> Answer<Value> {
        guard let client else { return .unavailable }
        do {
            return .value(try await body(client))
        } catch {
            return .failed(error.localizedDescription)
        }
    }
}

extension RunnerOracle.Answer: Equatable where Value: Equatable { }
