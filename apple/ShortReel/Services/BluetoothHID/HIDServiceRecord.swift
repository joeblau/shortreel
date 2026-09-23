import Foundation

enum HIDServiceRecord {

    static let reportDescriptor: [UInt8] = [
        0x05, 0x01,
        0x09, 0x02,
        0xA1, 0x01,
        0x85, 0x02,
        0x09, 0x01,
        0xA1, 0x00,
        0x05, 0x09,
        0x19, 0x01,
        0x29, 0x20,
        0x15, 0x00,
        0x25, 0x01,
        0x95, 0x20,
        0x75, 0x01,
        0x81, 0x02,
        0x05, 0x01,
        0x09, 0x30,
        0x09, 0x31,
        0x15, 0x00,
        0x26, 0xFF, 0x7F,
        0x75, 0x10,
        0x95, 0x02,
        0x81, 0x02,
        0xC0,
        0xC0,
        0x05, 0x01,
        0x09, 0x06,
        0xA1, 0x01,
        0x85, 0x01,
        0x05, 0x07,
        0x19, 0xE0,
        0x29, 0xE7,
        0x15, 0x00,
        0x25, 0x01,
        0x75, 0x01,
        0x95, 0x08,
        0x81, 0x02,
        0x95, 0x01,
        0x75, 0x08,
        0x81, 0x03,
        0x95, 0x05,
        0x75, 0x01,
        0x05, 0x08,
        0x19, 0x01,
        0x29, 0x05,
        0x91, 0x02,
        0x95, 0x01,
        0x75, 0x03,
        0x91, 0x03,
        0x95, 0x06,
        0x75, 0x08,
        0x15, 0x00,
        0x25, 0x65,
        0x05, 0x07,
        0x19, 0x00,
        0x29, 0x65,
        0x81, 0x00,
        0xC0,
    ]

    static func makeRecord(serviceName: String) -> Data {
        var attributes = Data()
        var attributeCount: UInt16 = 0
        func attr(_ id: UInt16, _ element: LocalSDPElement) {
            attributeCount += 1
            attributes.append(contentsOf: [UInt8(id & 0xFF), UInt8(id >> 8)])
            attributes.append(element.encoded)
        }

        attr(0x0001, .sequence([.uuid16(0x1124)]))
        attr(0x0004, .sequence([
            .sequence([.uuid16(0x0100), .uint16(0x0011)]),
            .sequence([.uuid16(0x0011)]),
        ]))
        attr(0x0005, .sequence([.uuid16(0x1002)]))
        attr(0x0006, .sequence([.uint16(0x656E), .uint16(0x006A), .uint16(0x0100)]))
        attr(0x0009, .sequence([.sequence([.uuid16(0x1124), .uint16(0x0101)])]))
        attr(0x000D, .sequence([
            .sequence([
                .sequence([.uuid16(0x0100), .uint16(0x0013)]),
                .sequence([.uuid16(0x0011)]),
            ]),
        ]))
        attr(0x0100, .text(serviceName))
        attr(0x0101, .text("AssistiveTouch pointer and keyboard"))
        attr(0x0201, .uint16(0x0111))
        attr(0x0202, .uint8(0xC0))
        attr(0x0203, .uint8(0x21))
        attr(0x0204, .boolean(true))
        attr(0x0205, .boolean(false))
        attr(0x0206, .sequence([
            .sequence([.uint8(0x22), .textBytes(reportDescriptor)]),
        ]))
        attr(0x0207, .sequence([.sequence([.uint16(0x0409), .uint16(0x0100)])]))
        attr(0x0208, .boolean(false))
        attr(0x0209, .boolean(true))
        attr(0x020A, .boolean(true))
        attr(0x020B, .uint16(0x0101))
        attr(0x020C, .uint16(0x0C80))
        attr(0x020D, .boolean(true))
        attr(0x020E, .boolean(false))

        var record = Data([UInt8(attributeCount & 0xFF), UInt8(attributeCount >> 8)])
        record.append(attributes)
        return record
    }
}

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
