import Foundation

struct PhoneScreenSource: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let deviceUniqueID: String
}

enum PhoneScreenSourceIdentity {
    static func canonicalPhysicalDeviceID(_ identifier: String) -> String? {
        guard identifier.range(of: #"^(?:[0-9A-Fa-f]{8}-[0-9A-Fa-f]{16}|[0-9A-Fa-f]{24}|[0-9A-Fa-f]{40})$"#,
                               options: .regularExpression) != nil else { return nil }
        return identifier.replacingOccurrences(of: "-", with: "").lowercased()
    }

    static func isPhysicalIOSDeviceID(_ identifier: String) -> Bool {
        canonicalPhysicalDeviceID(identifier) != nil
    }

    static func isEligible(uniqueID: String, manufacturer: String, isExternal: Bool,
                           modelID: String = "", isMuxed: Bool = false) -> Bool {
        guard isExternal, ["apple inc.", "apple"].contains(manufacturer.lowercased()) else { return false }
        return modelID == "iOS Device" && isMuxed
            && !uniqueID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

enum PhoneScreenCaptureError: LocalizedError, Sendable {
    case discoveryFailed(Int32)
    case permissionDenied
    case sourceUnavailable
    case sourceChanged
    case cannotAddInput
    case cannotAddOutput
    case notRunning
    case frameTimedOut
    case runtime(String)

    var errorDescription: String? {
        switch self {
        case .discoveryFailed(let status):
            "Could not enable USB phone screen discovery (macOS error \(status))."
        case .permissionDenied:
            "Allow Camera access for ShortReel in System Settings → Privacy & Security → Camera. macOS exposes the phone screen as a camera."
        case .sourceUnavailable:
            "The selected iPhone screen is unavailable. Connect that phone by USB, unlock it, and tap Trust on the phone, then refresh."
        case .sourceChanged:
            "The selected phone screen changed. Run the request again with the correct phone selected."
        case .cannotAddInput:
            "macOS could not open this iPhone screen. Close other apps using the phone screen and try again."
        case .cannotAddOutput:
            "macOS could not configure video frames from this iPhone. Reconnect its USB cable and try again."
        case .notRunning:
            "Connect the selected phone’s USB screen before running a visual request."
        case .frameTimedOut:
            "No fresh phone screen arrived. Check the USB cable, unlock the phone, and confirm Trust, then try again."
        case .runtime(let message):
            "Phone screen capture stopped: \(message)"
        }
    }
}
