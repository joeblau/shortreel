import Foundation

struct RunnerSigningIdentity: Sendable, Equatable, Hashable {
    var sha1: String
    var name: String
}

struct RunnerProducts: Sendable, Equatable {
    var runnerApp: URL
    var uitestRunnerApp: URL
}

enum ProvisioningStatus: Sendable, Equatable {
    case ready(identity: RunnerSigningIdentity, products: RunnerProducts)
    case goIosNotInstalled
    case noAppleDevelopmentIdentity
    case runnerProductsMissing(searchedDirectory: URL)
}

enum RunnerProvisioningError: Error, LocalizedError {
    case noAppleDevelopmentIdentity
    case runnerProductsNotFound(URL)

    var errorDescription: String? {
        switch self {
        case .noAppleDevelopmentIdentity:
            "No Apple Development signing identity found — open Xcode › Settings › Accounts, add your Apple ID, and create an Apple Development certificate."
        case .runnerProductsNotFound(let directory):
            "No built ShortReelRunner products under \(directory.path) — run `xcodebuild build-for-testing -scheme ShortReelRunner -destination 'generic/platform=iOS'` first."
        }
    }
}

struct RunnerProvisioning: Sendable {
    var processes: ProcessRunning
    var goIosExecutable = "ios"
    var securityExecutable = "/usr/bin/security"
    var runnerAppName = "ShortReelRunner.app"
    var uitestRunnerAppName = "ShortReelRunnerUITests-Runner.app"

    init(processes: ProcessRunning = SystemProcessRunner()) {
        self.processes = processes
    }

    func status(derivedData: URL) async -> ProvisioningStatus {
        guard (try? await goIosVersion()) != nil else { return .goIosNotInstalled }
        guard let identity = try? await appleDevelopmentIdentity() else { return .noAppleDevelopmentIdentity }
        guard let products = try? locateRunnerProducts(inDerivedData: derivedData) else {
            return .runnerProductsMissing(searchedDirectory: Self.productsDirectory(inDerivedData: derivedData))
        }
        return .ready(identity: identity, products: products)
    }

    func goIosVersion() async throws -> String {
        let result = try await processes.runChecked(ProcessInvocation(executable: goIosExecutable,
                                                                      arguments: ["version"]))
        return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func signingIdentities() async throws -> [RunnerSigningIdentity] {
        let result = try await processes.runChecked(ProcessInvocation(executable: securityExecutable,
                                                                      arguments: ["find-identity", "-v", "-p", "codesigning"]))
        return Self.parseSigningIdentities(result.stdout)
    }

    func appleDevelopmentIdentity() async throws -> RunnerSigningIdentity {
        let identity = try await signingIdentities().first {
            $0.name.hasPrefix("Apple Development:") || $0.name.hasPrefix("iPhone Developer:")
        }
        guard let identity else { throw RunnerProvisioningError.noAppleDevelopmentIdentity }
        return identity
    }

    func locateRunnerProducts(inDerivedData derivedData: URL) throws -> RunnerProducts {
        let productsDirectory = Self.productsDirectory(inDerivedData: derivedData)
        let configurations = (try? FileManager.default.contentsOfDirectory(at: productsDirectory, includingPropertiesForKeys: nil))?
            .filter { $0.lastPathComponent.hasSuffix("-iphoneos") }
            .sorted { $0.path < $1.path } ?? []
        for configuration in configurations {
            let runnerApp = configuration.appending(path: runnerAppName, directoryHint: .isDirectory)
            let uitestApp = configuration.appending(path: uitestRunnerAppName, directoryHint: .isDirectory)
            if FileManager.default.fileExists(atPath: runnerApp.path),
               FileManager.default.fileExists(atPath: uitestApp.path) {
                return RunnerProducts(runnerApp: runnerApp, uitestRunnerApp: uitestApp)
            }
        }
        throw RunnerProvisioningError.runnerProductsNotFound(productsDirectory)
    }

    @discardableResult
    func sign(runnerAppAt app: URL, p12: URL, profile: URL, output: URL? = nil) async throws -> URL {
        var arguments = ["sign", "app", "--path", app.path, "--p12file", p12.path, "--profile", profile.path]
        if let output {
            arguments += ["--output", output.path]
        }
        try await processes.runChecked(ProcessInvocation(executable: goIosExecutable, arguments: arguments))
        return output ?? app
    }

    func install(appAt app: URL, udid: String) async throws {
        try await processes.runChecked(ProcessInvocation(executable: goIosExecutable,
            arguments: ["install", "--path", app.path, "--udid", udid]))
    }

    static func parseSigningIdentities(_ output: String) -> [RunnerSigningIdentity] {
        output.split(separator: "\n").compactMap { rawLine in
            let line = rawLine.drop(while: { $0 == " " })
            guard let paren = line.firstIndex(of: ")"),
                  !line[..<paren].isEmpty, line[..<paren].allSatisfy(\.isNumber) else { return nil }
            let rest = line[line.index(after: paren)...].drop(while: { $0 == " " })
            guard let space = rest.firstIndex(of: " ") else { return nil }
            guard let firstQuote = rest.firstIndex(of: "\""),
                  let lastQuote = rest.lastIndex(of: "\""), firstQuote < lastQuote else { return nil }
            return RunnerSigningIdentity(sha1: String(rest[..<space]),
                                         name: String(rest[rest.index(after: firstQuote)..<lastQuote]))
        }
    }

    private static func productsDirectory(inDerivedData derivedData: URL) -> URL {
        derivedData.appending(path: "Build/Products", directoryHint: .isDirectory)
    }
}
