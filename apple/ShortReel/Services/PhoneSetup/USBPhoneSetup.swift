import Foundation
import Observation

struct ConnectedUSBPhone: Identifiable, Sendable, Equatable {
    var id: String
    var name: String
    var model: String?
    var bluetoothAddress: String?
    var trusted: Bool
    var assistiveTouchEnabled: Bool
    var status: String?

    init(_ snapshot: USBPhoneSnapshot) {
        id = snapshot.identifier
        name = snapshot.name
        model = snapshot.productType
        bluetoothAddress = snapshot.bluetoothAddress
        trusted = snapshot.trusted
        assistiveTouchEnabled = snapshot.assistiveTouchEnabled?.boolValue == true
        status = snapshot.statusMessage
    }
}

@Observable @MainActor
final class USBPhoneSetup {
    private(set) var phones: [ConnectedUSBPhone] = []
    private(set) var preparingIdentifier: String?
    private(set) var errorMessage: String?
    @ObservationIgnored private let bridge = USBPhoneBridge()
    @ObservationIgnored private var refreshing = false

    func refresh() async {
        guard !refreshing, preparingIdentifier == nil else { return }
        refreshing = true
        defer { refreshing = false }
        let result: ([ConnectedUSBPhone], String?) = await withCheckedContinuation { continuation in
            bridge.fetchConnectedPhones { snapshots, error in
                continuation.resume(returning: (snapshots.map(ConnectedUSBPhone.init), error?.localizedDescription))
            }
        }
        phones = result.0
        errorMessage = result.1
    }

    func prepare(_ phone: ConnectedUSBPhone) async throws -> ConnectedUSBPhone {
        preparingIdentifier = phone.id
        errorMessage = nil
        defer { preparingIdentifier = nil }
        do {
            if !phone.trusted {
                let _: ConnectedUSBPhone = try await withCheckedThrowingContinuation { continuation in
                    bridge.requestTrust(forIdentifier: phone.id) { snapshot, error in
                        Self.complete(continuation, snapshot: snapshot, error: error)
                    }
                }
            }
            try Task.checkCancellation()
            let prepared: ConnectedUSBPhone = try await withCheckedThrowingContinuation { continuation in
                bridge.preparePhone(withIdentifier: phone.id) { snapshot, error in
                    Self.complete(continuation, snapshot: snapshot, error: error)
                }
            }
            if let index = phones.firstIndex(where: { $0.id == prepared.id }) { phones[index] = prepared }
            return prepared
        } catch {
            errorMessage = error.localizedDescription
            throw error
        }
    }

    nonisolated private static func complete(
        _ continuation: CheckedContinuation<ConnectedUSBPhone, Error>,
        snapshot: USBPhoneSnapshot?, error: Error?
    ) {
        if let error { continuation.resume(throwing: error) }
        else if let snapshot { continuation.resume(returning: ConnectedUSBPhone(snapshot)) }
        else {
            continuation.resume(throwing: NSError(domain: "USBPhoneSetup", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "The phone disconnected during setup."]))
        }
    }
}
