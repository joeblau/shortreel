import Foundation

/// Builds the raw Bluetooth SDP record that makes this Mac appear as a HID
/// mouse + keyboard, using the same report descriptor TapKit publishes
/// (docs/tapkit-reverse-engineering.md §1).
enum HIDServiceRecord {

    /// Mouse with absolute X/Y in 0...32767 on report ID 2, plus a boot-style
    /// keyboard on report ID 1.
    static let reportDescriptor: [UInt8] = [
        // Mouse (absolute pointer), Report ID 2
        0x05, 0x01,       // Usage Page (Generic Desktop)
        0x09, 0x02,       // Usage (Mouse)
        0xA1, 0x01,       // Collection (Application)
        0x85, 0x02,       //   Report ID (2)
        0x09, 0x01,       //   Usage (Pointer)
        0xA1, 0x00,       //   Collection (Physical)
        0x05, 0x09,       //     Usage Page (Button)
        0x19, 0x01,       //     Usage Minimum (1)
        0x29, 0x20,       //     Usage Maximum (32)
        0x15, 0x00,       //     Logical Minimum (0)
        0x25, 0x01,       //     Logical Maximum (1)
        0x95, 0x20,       //     Report Count (32)
        0x75, 0x01,       //     Report Size (1)
        0x81, 0x02,       //     Input (Data, Var, Abs) — 4 button bytes
        0x05, 0x01,       //     Usage Page (Generic Desktop)
        0x09, 0x30,       //     Usage (X)
        0x09, 0x31,       //     Usage (Y)
        0x15, 0x00,       //     Logical Minimum (0)
        0x26, 0xFF, 0x7F, //     Logical Maximum (32767)
        0x75, 0x10,       //     Report Size (16)
        0x95, 0x02,       //     Report Count (2)
        0x81, 0x02,       //     Input (Data, Var, Abs) — absolute X/Y
        0xC0,             //   End Collection
        0xC0,             // End Collection
        // Keyboard, Report ID 1
        0x05, 0x01,       // Usage Page (Generic Desktop)
        0x09, 0x06,       // Usage (Keyboard)
        0xA1, 0x01,       // Collection (Application)
        0x85, 0x01,       //   Report ID (1)
        0x05, 0x07,       //   Usage Page (Key Codes)
        0x19, 0xE0,       //   Usage Minimum (224)
        0x29, 0xE7,       //   Usage Maximum (231)
        0x15, 0x00,       //   Logical Minimum (0)
        0x25, 0x01,       //   Logical Maximum (1)
        0x75, 0x01,       //   Report Size (1)
        0x95, 0x08,       //   Report Count (8)
        0x81, 0x02,       //   Input (Data, Var, Abs) — modifier byte
        0x95, 0x01,       //   Report Count (1)
        0x75, 0x08,       //   Report Size (8)
        0x81, 0x03,       //   Input (Const, Var, Abs) — reserved byte
        0x95, 0x05,       //   Report Count (5)
        0x75, 0x01,       //   Report Size (1)
        0x05, 0x08,       //   Usage Page (LEDs)
        0x19, 0x01,       //   Usage Minimum (1)
        0x29, 0x05,       //   Usage Maximum (5)
        0x91, 0x02,       //   Output (Data, Var, Abs)
        0x95, 0x01,       //   Report Count (1)
        0x75, 0x03,       //   Report Size (3)
        0x91, 0x03,       //   Output (Const, Var, Abs)
        0x95, 0x06,       //   Report Count (6)
        0x75, 0x08,       //   Report Size (8)
        0x15, 0x00,       //   Logical Minimum (0)
        0x25, 0x65,       //   Logical Maximum (101)
        0x05, 0x07,       //   Usage Page (Key Codes)
        0x19, 0x00,       //   Usage Minimum (0)
        0x29, 0x65,       //   Usage Maximum (101)
        0x81, 0x00,       //   Input (Data, Array) — 6 keycodes
        0xC0,             // End Collection
    ]

    /// CoreBluetooth's local-service format for `addServiceWithData:`:
    /// a little-endian UInt16 attribute count, then little-endian UInt16 IDs
    /// followed by serialized BT_DATAELEM values. This private API does not
    /// accept the on-air SDP encoding; bluetoothd converts the local format.
    static func makeRecord(serviceName: String) -> Data {
        var attributes = Data()
        var attributeCount: UInt16 = 0
        func attr(_ id: UInt16, _ element: LocalSDPElement) {
            attributeCount += 1
            attributes.append(contentsOf: [UInt8(id & 0xFF), UInt8(id >> 8)])
            attributes.append(element.encoded)
        }

        // ServiceClassIDList: HumanInterfaceDeviceService
        attr(0x0001, .sequence([.uuid16(0x1124)]))
        // ProtocolDescriptorList: L2CAP (PSM HID Control), HIDP
        attr(0x0004, .sequence([
            .sequence([.uuid16(0x0100), .uint16(0x0011)]),
            .sequence([.uuid16(0x0011)]),
        ]))
        // BrowseGroupList: PublicBrowseRoot
        attr(0x0005, .sequence([.uuid16(0x1002)]))
        // LanguageBaseAttributeIDList: "en", 0x006A, base 0x0100
        attr(0x0006, .sequence([.uint16(0x656E), .uint16(0x006A), .uint16(0x0100)]))
        // BluetoothProfileDescriptorList: HID 1.1
        attr(0x0009, .sequence([.sequence([.uuid16(0x1124), .uint16(0x0101)])]))
        // AdditionalProtocolDescriptorLists: L2CAP (PSM HID Interrupt), HIDP
        attr(0x000D, .sequence([
            .sequence([
                .sequence([.uuid16(0x0100), .uint16(0x0013)]),
                .sequence([.uuid16(0x0011)]),
            ]),
        ]))
        // ServiceName (language base 0x0100)
        attr(0x0100, .text(serviceName))
        attr(0x0101, .text("AssistiveTouch pointer and keyboard"))
        // Bluetooth SIG HID attribute IDs start at 0x0201. 0x0200 is the
        // deprecated HIDDeviceReleaseNumber, not HIDParserVersion. Shifting
        // these IDs makes hosts read the wrong types and lose the report map.
        attr(0x0201, .uint16(0x0111))   // HIDParserVersion 1.11
        attr(0x0202, .uint8(0xC0))      // HIDDeviceSubclass: combo keyboard/pointer
        attr(0x0203, .uint8(0x21))      // HIDCountryCode: US
        attr(0x0204, .boolean(true))    // HIDVirtualCable
        attr(0x0205, .boolean(false))   // HIDReconnectInitiate: phone initiates connections
        // HIDDescriptorList: report map
        attr(0x0206, .sequence([
            .sequence([.uint8(0x22), .textBytes(reportDescriptor)]),
        ]))
        // HIDLANGIDBaseList: en_US at base 0x0100
        attr(0x0207, .sequence([.sequence([.uint16(0x0409), .uint16(0x0100)])]))
        attr(0x0208, .boolean(false))   // HIDSDPDisable
        attr(0x0209, .boolean(true))    // HIDBatteryPower
        attr(0x020A, .boolean(true))    // HIDRemoteWake
        attr(0x020B, .uint16(0x0101))   // HIDProfileVersion: matches profile descriptor list
        attr(0x020C, .uint16(0x0C80))   // HIDSupervisionTimeout
        attr(0x020D, .boolean(true))    // HIDNormallyConnectable
        attr(0x020E, .boolean(false))   // HIDBootDevice

        var record = Data([UInt8(attributeCount & 0xFF), UInt8(attributeCount >> 8)])
        record.append(attributes)
        return record
    }
}

/// CoreBluetooth local BT_DATAELEM serialization, verified against
/// bluetoothd's BT_DataElement_Extract. Each element has a type byte and a
/// little-endian UInt16 size. Sequences use child counts, not byte lengths;
/// small integers/UUIDs occupy a UInt32 slot regardless of their declared size.
indirect enum LocalSDPElement {
    case uint8(UInt8)
    case uint16(UInt16)
    case uuid16(UInt16)
    case boolean(Bool)
    case text(String)
    case textBytes([UInt8])
    case sequence([LocalSDPElement])

    var encoded: Data {
        switch self {
        case .uint8(let value):
            return Self.header(type: 1, size: 1) + Self.integer(UInt32(value))
        case .uint16(let value):
            return Self.header(type: 1, size: 2) + Self.integer(UInt32(value))
        case .uuid16(let value):
            return Self.header(type: 3, size: 2) + Self.integer(UInt32(value))
        case .boolean(let value):
            return Self.header(type: 5, size: 1) + Data([value ? 1 : 0])
        case .text(let string):
            return LocalSDPElement.textBytes(Array(string.utf8)).encoded
        case .textBytes(let bytes):
            return Self.header(type: 4, size: bytes.count) + Data(bytes)
        case .sequence(let children):
            var data = Self.header(type: 6, size: children.count)
            for child in children { data.append(child.encoded) }
            return data
        }
    }

    private static func header(type: UInt8, size: Int) -> Data {
        precondition(size <= UInt16.max)
        return Data([type, UInt8(size & 0xFF), UInt8(size >> 8)])
    }

    private static func integer(_ value: UInt32) -> Data {
        Data((0..<4).map { UInt8((value >> ($0 * 8)) & 0xFF) })
    }
}
