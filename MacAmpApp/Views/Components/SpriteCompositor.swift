import AppKit

/// Flattens a set of sprite blits into one bitmap so a layer can present them
/// through a single `Image` instead of one view per sprite.
///
/// The bitmap route is what keeps the result exact. A `Canvas` rasterizes into a
/// backing store whose scale it picks itself, and that choice differs across
/// macOS versions; a canvas rasterized at 1x and then magnified into a 2x window
/// softens every edge, which pixel art cannot absorb. SwiftUI draws an `Image`
/// at the final device scale instead, so one source pixel lands on a whole
/// number of screen pixels.
enum SpriteCompositor {

    /// Draws `blits` into a `size`-point bitmap at one pixel per point, using a
    /// top-left origin to match sprite-sheet coordinates. Sprites are copied
    /// without interpolation or antialiasing, in the order given.
    ///
    /// Returns nil when `size` is empty or the bitmap cannot be allocated.
    static func flatten(_ blits: [(image: NSImage, origin: CGPoint, size: CGSize)],
                        into size: CGSize) -> NSImage? {
        let width = Int(size.width), height = Int(size.height)
        guard width > 0, height > 0,
              let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                  data: nil,
                  width: width,
                  height: height,
                  bitsPerComponent: 8,
                  bytesPerRow: width * 4,
                  space: colorSpace,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else { return nil }

        context.interpolationQuality = .none
        context.setShouldAntialias(false)

        for blit in blits {
            guard let cgImage = blit.image.cgImage(forProposedRect: nil, context: nil, hints: nil)
            else { continue }
            context.draw(cgImage, in: CGRect(
                x: blit.origin.x,
                y: size.height - blit.origin.y - blit.size.height,
                width: blit.size.width,
                height: blit.size.height
            ))
        }

        guard let flattened = context.makeImage() else { return nil }
        return NSImage(cgImage: flattened, size: size)
    }
}
