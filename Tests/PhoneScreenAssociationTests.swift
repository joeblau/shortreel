import Foundation

// swiftc -swift-version 6 ShortReel/Services/PhoneScreenCapture/PhoneScreenSource.swift ShortReel/Services/PhoneScreenCapture/PhoneScreenAssociation.swift Tests/PhoneScreenAssociationTests.swift -o /tmp/shortreel-screen-association-tests
@main
enum PhoneScreenAssociationTests {
    private static let phoneID = "00008130-000161141E43001C"
    private static let otherPhoneID = "00008130-000161141E43001D"
    private static let oldPhoneID = "1234567890abcdef1234567890abcdef12345678"
    private static let privacyID = "37AC1A53-65FF-4A8A-B7F3-EE145C7F8631"
    private static let secondPrivacyID = "37AC1A53-65FF-4A8A-B7F3-EE145C7F8632"
    private static let address = "AA:BB:CC:DD:EE:15"
    private static let otherAddress = "AA:BB:CC:DD:EE:16"

    static func main() {
        let phone = identity()
        let source = screen()

        // The attached phone's AVFoundation identity is a privacy UUID, while
        // MobileDevice reports a different physical USB identity.
        expect([phone], [source], privacyID)
        expect([identity(name: " SOCIAL15PRO\n")], [screen(name: "social15pro")], privacyID)
        expect([identity(name: "Renée")], [screen(name: "Rene\u{301}e")], privacyID)

        for spelling in ["aabbccddee15", "AA-BB-CC-DD-EE-15", "aabb.ccdd.ee15", "AA BB CC DD EE 15", " \nAA:BB:CC:DD:EE:15\t"] {
            precondition(PhoneScreenAssociation.selectedPhone(bluetoothAddress: spelling, phones: [phone]) == phone)
            precondition(PhoneScreenAssociation.selectedPhone(bluetoothAddress: address, phones: [identity(address: spelling)]) != nil)
            expect([phone], [source], privacyID, address: spelling)
        }
        for invalid in ["", "AA:BB:CC:DD:EE", "AA:BB:CC:DD:EE:15:00", "GG:BB:CC:DD:EE:15", "AA:BB-CC:DD:EE:15",
                        "Address AA:BB:CC:DD:EE:15", "AA::BB::CC::DD::EE::15", "AA:BB:CC:DD:EE:15?", "AABBCCDDEE15garbage"] {
            precondition(PhoneScreenAssociation.selectedPhone(bluetoothAddress: invalid, phones: [phone]) == nil)
            expect([identity(address: invalid)], [source], nil)
        }

        // Physical IDs are authoritative, independent of friendly names and the
        // number or order of other connected phones/screens.
        let physical = screen(id: "physical-source", name: "Another visible name", uniqueID: phoneID.lowercased().replacingOccurrences(of: "-", with: ""))
        expect([phone], [physical], "physical-source")
        expect([identity(id: phoneID.replacingOccurrences(of: "-", with: ""))], [screen(id: "physical-source", uniqueID: phoneID)], "physical-source")
        expect([identity(id: oldPhoneID)], [screen(id: "old-source", uniqueID: oldPhoneID.uppercased())], "old-source")
        let other = identity(id: otherPhoneID, name: "Other Phone", address: otherAddress)
        let otherPhysical = screen(id: "other-source", name: "Other Phone", uniqueID: otherPhoneID)
        expect([other, phone], [otherPhysical, physical], "physical-source")
        expect([phone, other], [physical, otherPhysical], "physical-source")
        expect([phone, other], [source, physical], "physical-source")

        // Name fallback never chooses among multiple connected devices/sources,
        // even if only one name matches or an extra device has not been trusted.
        expect([phone, other], [source], nil)
        expect([phone, identity(id: otherPhoneID, address: otherAddress, trusted: false)], [source], nil)
        expect([phone], [source, screen(id: secondPrivacyID, name: "Other Phone")], nil)
        expect([phone], [screen(name: "Other Phone")], nil)
        expect([identity(name: "")], [screen(name: "")], nil)
        expect([identity(name: "SOCIAL 15 PRO")], [screen(name: "SOCIAL  15 PRO")], nil)
        expect([identity(trusted: false)], [source], nil)
        expect([identity(address: nil)], [source], nil)
        expect([identity(address: otherAddress)], [source], nil)
        expect([identity(id: "not-a-USB-UDID")], [source], nil)
        expect([phone], [screen(id: "unknown-opaque-id", uniqueID: "unknown-opaque-id")], nil)
        expect([phone], [screen(uniqueID: otherPhoneID)], nil)
        expect([phone], [screen(id: "", uniqueID: privacyID)], nil)
        expect([], [source], nil)
        expect([phone], [], nil)

        // Duplicate identities and duplicate matching Bluetooth addresses reject
        // the entire association instead of selecting whichever appears first.
        expect([phone, phone], [physical], nil)
        expect([phone, identity(id: phoneID.replacingOccurrences(of: "-", with: ""), address: otherAddress)], [physical], nil)
        expect([phone, identity(id: otherPhoneID)], [physical], nil)
        expect([phone, identity(id: otherPhoneID, trusted: false)], [physical], nil)
        expect([phone], [physical, physical], nil)
        expect([phone], [physical, screen(id: "PHYSICAL-SOURCE", uniqueID: otherPhoneID)], nil)
        expect([phone], [physical, screen(id: "another-physical-source", uniqueID: phoneID)], nil)
        expect([phone], [source, screen(id: privacyID.lowercased())], nil)
        expect([phone], [physical, screen(id: "duplicate-one", uniqueID: privacyID), screen(id: "duplicate-two", uniqueID: privacyID.lowercased())], nil)

        print("Phone screen association tests passed")
    }

    private static func identity(id: String = phoneID, name: String = "SOCIAL15PRO", address: String? = address, trusted: Bool = true) -> PhoneScreenPhoneIdentity {
        .init(id: id, name: name, bluetoothAddress: address, trusted: trusted)
    }

    private static func screen(id: String = privacyID, name: String = "SOCIAL15PRO", uniqueID: String? = nil) -> PhoneScreenSource {
        .init(id: id, name: name, deviceUniqueID: uniqueID ?? id)
    }

    private static func expect(_ phones: [PhoneScreenPhoneIdentity], _ sources: [PhoneScreenSource], _ expected: String?, address: String = address) {
        let actual = PhoneScreenAssociation.matchingSource(bluetoothAddress: address, phones: phones, sources: sources)
        precondition(actual == expected, "Expected source \(String(describing: expected)), received \(String(describing: actual))")
    }
}
