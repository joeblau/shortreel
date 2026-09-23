import Foundation

@main
enum HIDServiceRecordTests {
    struct Element {
        let type: UInt8
        let size: Int
        let bytes: [UInt8]
        var items: [Element] = []

        var number: Int { bytes.reversed().reduce(0) { ($0 << 8) | Int($1) } }

        func children() -> [Element] {
            precondition(type == 6, "Expected an SDP sequence")
            return items
        }
    }

    struct Reader {
        let bytes: [UInt8]
        var offset = 0

        mutating func take(_ count: Int) -> [UInt8] {
            precondition(offset + count <= bytes.count, "Truncated SDP element")
            defer { offset += count }
            return Array(bytes[offset..<(offset + count)])
        }

        mutating func littleEndian16() -> Int {
            let value = take(2)
            return Int(value[0]) | (Int(value[1]) << 8)
        }

        mutating func element() -> Element {
            let type = take(1)[0]
            let size = littleEndian16()
            if type == 6 {
                let children = (0..<size).map { _ in element() }
                return Element(type: type, size: size, bytes: [], items: children)
            }
            precondition([1, 3, 4, 5].contains(type), "Unexpected local element type")
            let length = (type == 1 || type == 3) ? 4 : size
            return Element(type: type, size: size, bytes: take(length))
        }
    }

    static func main() {
        for name in ["ShortReel", "Joe’s Mac", String(repeating: "M", count: 300)] {
            var reader = Reader(bytes: Array(HIDServiceRecord.makeRecord(serviceName: name)))
            let count = reader.littleEndian16()
            precondition(count == 22, "Wrong local-service attribute count/framing")
            var attributes: [Int: Element] = [:]
            for _ in 0..<count {
                let id = reader.littleEndian16()
                precondition(attributes[id] == nil, "Duplicate attribute")
                attributes[id] = reader.element()
            }
            precondition(reader.offset == reader.bytes.count, "Trailing record bytes")

            let requiredTypes: [Int: UInt8] = [
                0x0201: 1, 0x0202: 1, 0x0203: 1,
                0x0204: 5, 0x0205: 5, 0x0206: 6, 0x0207: 6,
                0x0208: 5, 0x0209: 5, 0x020A: 5, 0x020B: 1,
                0x020C: 1, 0x020D: 5, 0x020E: 5,
            ]
            for (id, type) in requiredTypes {
                precondition(attributes[id]?.type == type, "Missing/mistyped HID attribute \(id)")
            }
            precondition(attributes[0x0201]?.number == 0x0111 && attributes[0x0201]?.size == 2)
            precondition(attributes[0x0202]?.number == 0xC0 && attributes[0x0202]?.size == 1)
            precondition(attributes[0x0203]?.number == 0x21 && attributes[0x0203]?.size == 1)
            precondition(attributes[0x0205]?.number == 0, "Host initiates reconnection")

            let descriptor = attributes[0x0206]!.children()[0].children()
            precondition(descriptor.count == 2 && descriptor[0].number == 0x22)
            precondition(descriptor[1].type == 4)
            precondition(descriptor[1].bytes == HIDServiceRecord.reportDescriptor)
            let language = attributes[0x0207]!.children()[0].children()
            precondition(language.map(\.number) == [0x0409, 0x0100])

            let profile = attributes[0x0009]!.children()[0].children()
            precondition(profile[0].type == 3 && profile[0].number == 0x1124)
            precondition(profile[1].number == 0x0101)
            precondition(profile[1].number == attributes[0x020B]?.number)
            let control = attributes[0x0004]!.children()[0].children()
            let interrupt = attributes[0x000D]!.children()[0].children()[0].children()
            precondition(control.map(\.number) == [0x0100, 0x0011])
            precondition(interrupt.map(\.number) == [0x0100, 0x0013])
            precondition(attributes[0x0100]?.type == 4)
            precondition(attributes[0x0100]?.bytes == Array(name.utf8))
        }
        print("HID service record tests passed")
    }
}
