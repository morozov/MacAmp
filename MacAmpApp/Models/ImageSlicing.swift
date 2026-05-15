import AppKit
import CoreGraphics

extension NSImage {
    // Crops the NSImage to the specified rectangle.
    // Creates an independent CGImage copy to break parent buffer reference chains,
    // preventing the parent BMP's full pixel buffer from being retained by cropped sprites.
    func cropped(to rect: CGRect) -> NSImage? {
        guard let cgImage = self.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            AppLog.error(.ui, "ImageSlicing: Failed to get CGImage from NSImage")
            return nil
        }

        // Clamp to bounds: BMP heights vary across skins, and scaling would interpolate magenta separators.
        let imageBounds = CGRect(x: 0, y: 0, width: CGFloat(cgImage.width), height: CGFloat(cgImage.height))
        let clampedRect = rect.intersection(imageBounds)
        guard !clampedRect.isNull, clampedRect.width > 0, clampedRect.height > 0 else {
            AppLog.error(.ui, "ImageSlicing: Rect \(rect) is outside image bounds \(imageBounds)")
            return nil
        }

        guard let croppedCGImage = cgImage.cropping(to: clampedRect) else {
            AppLog.error(.ui, "ImageSlicing: CGImage.cropping failed for rect \(clampedRect)")
            return nil
        }

        // Create an independent copy via canonical RGBA8 CGContext to break the
        // parent-child buffer sharing that CGImage.cropping(to:) creates.
        // Without this, the parent BMP's full float pixel buffer stays alive
        // as long as any cropped sprite references it.
        let width = Int(clampedRect.width)
        let height = Int(clampedRect.height)
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                  data: nil,
                  width: width,
                  height: height,
                  bitsPerComponent: 8,
                  bytesPerRow: width * 4,
                  space: colorSpace,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else {
            AppLog.error(.ui, "ImageSlicing: Failed to create independent CGContext for \(rect)")
            return nil
        }
        context.draw(croppedCGImage, in: CGRect(origin: .zero, size: clampedRect.size))

        // Winamp chroma key: RGB(255, 0, 255) marks transparent.
        if let data = context.data {
            let buffer = data.bindMemory(to: UInt8.self, capacity: width * height * 4)
            for i in stride(from: 0, to: width * height * 4, by: 4) {
                if buffer[i] == 255, buffer[i + 1] == 0, buffer[i + 2] == 255 {
                    buffer[i] = 0
                    buffer[i + 1] = 0
                    buffer[i + 2] = 0
                    buffer[i + 3] = 0
                }
            }
        }

        guard let independentCGImage = context.makeImage() else {
            AppLog.error(.ui, "ImageSlicing: Failed to create independent CGImage for \(clampedRect)")
            return nil
        }
        return NSImage(cgImage: independentCGImage, size: clampedRect.size)
    }
}
