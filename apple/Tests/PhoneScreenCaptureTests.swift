import CoreImage
import Foundation
import ImageIO

@main
struct PhoneScreenCaptureTests {
    @MainActor static func main() async throws {
        let modernPhone = "00008130-000161141E43001C"
        let legacyPhone = "1234567890abcdef1234567890abcdef12345678"
        expect(PhoneScreenSourceIdentity.isEligible(uniqueID: modernPhone,
            manufacturer: "Apple Inc.", isExternal: true, modelID: "iOS Device", isMuxed: true),
            "modern physical iPhone screen identity")
        expect(PhoneScreenSourceIdentity.isEligible(uniqueID: legacyPhone,
            manufacturer: "Apple Inc.", isExternal: true, modelID: "iOS Device", isMuxed: true),
            "legacy physical iPhone screen identity")
        for identifier in ["", "SOCIAL15PRO", "iPhone", "768D5582-FB81-43FA-9FC6-EF4EDB66A535",
                           "00008130-000161141E43001C-camera", "0x1450000005ac8514", "00008130-000161141E43001G"] {
            expect(!PhoneScreenSourceIdentity.isEligible(uniqueID: identifier,
                manufacturer: "Apple Inc.", isExternal: true), "reject non-phone identifier \(identifier)")
        }
        expect(!PhoneScreenSourceIdentity.isEligible(uniqueID: modernPhone,
            manufacturer: "EcammLive", isExternal: true, modelID: "iOS Device", isMuxed: true),
            "reject non-Apple virtual input")
        expect(!PhoneScreenSourceIdentity.isEligible(uniqueID: modernPhone,
            manufacturer: "Apple Inc.", isExternal: false, modelID: "iOS Device", isMuxed: true),
            "reject built-in and Continuity cameras")

        let opaqueScreenID = "37AC1A53-65FF-4A8A-B7F3-EE145C7F8631"
        expect(PhoneScreenSourceIdentity.isEligible(uniqueID: opaqueScreenID,
            manufacturer: "Apple Inc.", isExternal: true, modelID: "iOS Device", isMuxed: true),
            "accept the actual macOS 27 muxed iPhone screen with an opaque UUID")
        expect(!PhoneScreenSourceIdentity.isEligible(uniqueID: opaqueScreenID,
            manufacturer: "Apple Inc.", isExternal: true, modelID: "iOS Device", isMuxed: false),
            "a UUID and model name alone must not identify a camera as a phone screen")
        expect(!PhoneScreenSourceIdentity.isEligible(uniqueID: opaqueScreenID,
            manufacturer: "Apple Inc.", isExternal: true, modelID: "FaceTime HD Camera", isMuxed: true),
            "an Apple camera must not qualify as an iOS screen")
        expect(PhoneScreenSourceIdentity.canonicalPhysicalDeviceID(modernPhone)
            == PhoneScreenSourceIdentity.canonicalPhysicalDeviceID("00008130000161141e43001c"),
            "physical USB IDs match despite case and hyphen formatting")
        expect(PhoneScreenSourceIdentity.canonicalPhysicalDeviceID(opaqueScreenID) == nil,
            "never treat an opaque capture UUID as a physical USB UDID")

        let context = CIContext(options: [.useSoftwareRenderer: true])
        for dimensions in [(1179, 2556), (2556, 1179), (1201, 2601), (320, 480)] {
            let image = CIImage(color: CIColor(red: 0.1, green: 0.3, blue: 0.5)).cropped(to:
                CGRect(x: 0, y: 0, width: dimensions.0, height: dimensions.1))
            let capturedAt = Date()
            guard let frame = PhoneScreenFrameEncoder.encode(image, using: context,
                capturedAt: capturedAt, sourceID: modernPhone),
                  let source = CGImageSourceCreateWithData(frame.jpegData as CFData, nil),
                  let decoded = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
                fatalError("Phone-sized image must encode and decode.")
            }
            expect(frame.pixelWidth == decoded.width && frame.pixelHeight == decoded.height,
                   "published dimensions must exactly match the JPEG after fractional scaling")
            expect(max(decoded.width, decoded.height) <= 1280, "JPEG longest edge must be bounded")
            expect(frame.sourceID == modernPhone && frame.capturedAt == capturedAt,
                   "encoding must preserve source identity and capture timestamp")
        }

        let service = PhoneScreenCaptureService()
        do {
            _ = try await service.capture()
            fatalError("Stopped capture must fail without returning an image.")
        } catch PhoneScreenCaptureError.notRunning { }
        try await service.refresh()
        expect(service.sources.allSatisfy { $0.id == $0.deviceUniqueID && !$0.id.isEmpty },
            "real read-only discovery preserves exact opaque capture identities")
        expect(!service.sources.contains(where: { $0.id == "768D5582-FB81-43FA-9FC6-EF4EDB66A535" }),
            "the observed Ecamm virtual camera must remain excluded")
        expect(!service.isRunning && service.latestFrame == nil, "discovery must not open any capture input")
        await service.stop()
        print("Phone screen capture tests passed (\(service.sources.count) eligible USB screen sources; no input opened).")
    }

    private static func expect(_ value: @autoclosure () -> Bool, _ message: String) {
        if !value() { fatalError(message) }
    }
}
