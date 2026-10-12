import Foundation

/// Gates behavior that must not reach the user from the unit-test process:
/// sound, Now Playing, media keys and the user's files.
enum UnitTestSupport {
    /// XCTest is loaded into every test process, Swift Testing runs included.
    static let isActive = NSClassFromString("XCTestCase") != nil

    /// The Application Support directory; a throwaway one in the test process.
    static var applicationSupportDirectory: URL? {
        isActive
            ? testApplicationSupportDirectory
            : FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
    }

    private static let testApplicationSupportDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent("MacAmpUnitTests-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
}
