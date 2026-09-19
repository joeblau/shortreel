import Foundation

struct PhoneScreenPhoneIdentity: Sendable, Equatable {
    let id: String
    let name: String
    let bluetoothAddress: String?
    let trusted: Bool
}

/// Associates an already-filtered iOS screen source with the phone receiving HID
/// input. Friendly names never choose among multiple phones or screen sources.
enum PhoneScreenAssociation {
    static func selectedPhone(bluetoothAddress: String, phones: [PhoneScreenPhoneIdentity]) -> PhoneScreenPhoneIdentity? {
        guard let address = canonicalBluetoothAddress(bluetoothAddress),
              hasUniqueIdentities(phones.map(\.id)) else { return nil }
        let matching = phones.filter { phone in
            phone.bluetoothAddress.flatMap(canonicalBluetoothAddress) == address
        }
        guard matching.count == 1, let phone = matching.first, phone.trusted,
              canonicalPhysicalDeviceID(phone.id) != nil else { return nil }
        return phone
    }

    static func matchingSource(bluetoothAddress: String, phones: [PhoneScreenPhoneIdentity], sources: [PhoneScreenSource]) -> String? {
        guard let phone = selectedPhone(bluetoothAddress: bluetoothAddress, phones: phones),
              let physicalID = canonicalPhysicalDeviceID(phone.id),
              hasUniqueIdentities(sources.map(\.id)),
              hasUniqueIdentities(sources.map(\.deviceUniqueID)) else { return nil }

        let physicalMatches = sources.filter {
            canonicalPhysicalDeviceID($0.deviceUniqueID) == physicalID
        }
        if physicalMatches.count == 1 { return physicalMatches[0].id }
        guard physicalMatches.isEmpty else { return nil }

        // Current macOS can expose the iOS screen under an opaque privacy UUID
        // instead of its USB UDID. This fallback is deliberately unavailable if
        // any second phone/source could make the same-name association ambiguous.
        guard phones.count == 1, sources.count == 1, let source = sources.first,
              UUID(uuidString: source.deviceUniqueID.trimmingCharacters(in: .whitespacesAndNewlines)) != nil else { return nil }
        let phoneName = canonicalName(phone.name)
        guard !phoneName.isEmpty, canonicalName(source.name) == phoneName else { return nil }
        return source.id
    }

    private static func canonicalBluetoothAddress(_ input: String) -> String? {
        let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        // Accept conventional address spellings, never remove arbitrary text to
        // manufacture twelve hex digits from a malformed identifier.
        let validPatterns = [
            #"^[0-9A-Fa-f]{12}$"#,
            #"^(?:[0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}$"#,
            #"^(?:[0-9A-Fa-f]{2}-){5}[0-9A-Fa-f]{2}$"#,
            #"^(?:[0-9A-Fa-f]{4}\.){2}[0-9A-Fa-f]{4}$"#,
            #"^(?:[0-9A-Fa-f]{2}[ \t]+){5}[0-9A-Fa-f]{2}$"#,
        ]
        guard validPatterns.contains(where: { value.range(of: $0, options: .regularExpression) != nil }) else { return nil }
        return value.filter { $0.isASCII && $0.isHexDigit }.uppercased()
    }

    private static func canonicalPhysicalDeviceID(_ input: String) -> String? {
        let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.range(of: #"^(?:[0-9A-Fa-f]{8}-[0-9A-Fa-f]{16}|[0-9A-Fa-f]{24}|[0-9A-Fa-f]{40})$"#,
                          options: .regularExpression) != nil else { return nil }
        return value.replacingOccurrences(of: "-", with: "").lowercased()
    }

    private static func hasUniqueIdentities(_ identifiers: [String]) -> Bool {
        var seen = Set<String>()
        for identifier in identifiers {
            let trimmed = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return false }
            let key: String
            if let physical = canonicalPhysicalDeviceID(trimmed) {
                key = physical
            } else if let uuid = UUID(uuidString: trimmed) {
                key = uuid.uuidString.lowercased()
            } else {
                key = trimmed.lowercased()
            }
            guard seen.insert(key).inserted else { return false }
        }
        return true
    }

    private static func canonicalName(_ input: String) -> String {
        input.trimmingCharacters(in: .whitespacesAndNewlines)
            .precomposedStringWithCanonicalMapping
            .folding(options: [.caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }
}
