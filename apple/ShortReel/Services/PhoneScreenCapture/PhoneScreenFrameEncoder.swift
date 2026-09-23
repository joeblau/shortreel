import CoreImage
import Foundation
import ImageIO

enum PhoneScreenFrameEncoder {
    static func encode(_ image: CIImage, using context: CIContext,
                       capturedAt: Date, sourceID: String) -> PhoneScreenFrame? {
        let extent = image.extent
        guard extent.width.isFinite, extent.height.isFinite,
              extent.width >= 1, extent.height >= 1 else { return nil }
        let scale = min(1, 1280 / max(extent.width, extent.height))
        let translated = image.transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY))
        let scaled = translated.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let bounds = CGRect(x: 0, y: 0, width: max(1, floor(min(1280, scaled.extent.width))),
                            height: max(1, floor(min(1280, scaled.extent.height))))
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let data = context.jpegRepresentation(of: scaled.cropped(to: bounds), colorSpace: colorSpace,
                options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: 0.8]),
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil),
              cgImage.width > 0, cgImage.height > 0, cgImage.width <= 1280, cgImage.height <= 1280 else { return nil }
        return PhoneScreenFrame(id: UUID(), capturedAt: capturedAt, pixelWidth: cgImage.width,
                                pixelHeight: cgImage.height, jpegData: data, cgImage: cgImage, sourceID: sourceID)
    }
}
