import CoreGraphics
import Foundation
import ImageIO
import Vision

nonisolated struct NearDuplicatePhoto {
    private static let side = 64
    private static let maximumAspectRatioDifference = 0.015
    private static let maximumFeatureDistance: Float = 0.25
    private static let maximumMeanColorDifference = 3
    private static let maximumTileColorDifference = 8

    private let aspectRatio: Double
    private let pixels: [UInt8]
    private let features: VNFeaturePrintObservation

    init(data: Data) throws {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Double,
              let height = properties[kCGImagePropertyPixelHeight] as? Double,
              width > 0, height > 0,
              let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 256
              ] as CFDictionary) else {
            throw CocoaError(.fileReadCorruptFile)
        }

        let orientation = properties[kCGImagePropertyOrientation] as? Int ?? 1
        aspectRatio = (5...8).contains(orientation) ? height / width : width / height
        pixels = try Self.normalizedPixels(thumbnail)

        let request = VNGenerateImageFeaturePrintRequest()
        request.revision = VNGenerateImageFeaturePrintRequestRevision2
        try VNImageRequestHandler(cgImage: thumbnail).perform([request])
        guard let features = request.results?.first else {
            throw CocoaError(.fileReadCorruptFile)
        }
        self.features = features
    }

    func matches(_ other: Self) -> Bool {
        let ratioDifference = abs(aspectRatio - other.aspectRatio) / max(aspectRatio, other.aspectRatio)
        guard ratioDifference <= Self.maximumAspectRatioDifference,
              hasSmallColorDifference(from: other) else { return false }

        var distance: Float = 0
        do {
            try features.computeDistance(&distance, to: other.features)
            return distance <= Self.maximumFeatureDistance
        } catch {
            return false
        }
    }

    private static func normalizedPixels(_ image: CGImage) throws -> [UInt8] {
        let stride = side * 4
        var pixels = [UInt8](repeating: 0, count: stride * side)
        try pixels.withUnsafeMutableBytes { buffer in
            guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
                  let context = CGContext(
                    data: buffer.baseAddress,
                    width: side,
                    height: side,
                    bitsPerComponent: 8,
                    bytesPerRow: stride,
                    space: colorSpace,
                    bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.noneSkipLast.rawValue
                  ) else {
                throw CocoaError(.fileReadCorruptFile)
            }
            let bounds = CGRect(x: 0, y: 0, width: side, height: side)
            context.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
            context.fill(bounds)
            context.interpolationQuality = .high
            context.draw(image, in: bounds)
        }
        return pixels
    }

    private func hasSmallColorDifference(from other: Self) -> Bool {
        let tileSide = 8
        let channelCountPerTile = tileSide * tileSide * 3
        var totalDifference = 0

        for tileY in stride(from: 0, to: Self.side, by: tileSide) {
            for tileX in stride(from: 0, to: Self.side, by: tileSide) {
                var difference = 0
                for y in tileY..<(tileY + tileSide) {
                    for x in tileX..<(tileX + tileSide) {
                        let offset = (y * Self.side + x) * 4
                        for channel in offset..<(offset + 3) {
                            difference += abs(Int(pixels[channel]) - Int(other.pixels[channel]))
                        }
                    }
                }
                if difference > Self.maximumTileColorDifference * channelCountPerTile {
                    return false
                }
                totalDifference += difference
            }
        }

        return totalDifference <= Self.maximumMeanColorDifference * Self.side * Self.side * 3
    }
}
