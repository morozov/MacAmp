import Foundation

/// Files under `Fixtures/`.
enum Fixtures {
    static func url(_ name: String, withExtension ext: String? = nil) -> URL? {
        #if SWIFT_PACKAGE
        Bundle.module.url(forResource: name, withExtension: ext)
        #else
        Bundle(for: BundleToken.self).url(forResource: name, withExtension: ext)
        #endif
    }

    private final class BundleToken {}
}
