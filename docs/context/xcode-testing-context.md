# Xcode Testing Context (MacAmp)

## Purpose

This document gives a fast, practical overview of the MacAmp Xcode test setup so another agent can run and extend tests quickly, with a focus on concurrency-related coverage.

## Test Setup Overview

- **Scheme**: `MacAmpApp`
- **Test target**: `MacAmpTests` (`Tests/MacAmpTests`)
- **Test framework**: Swift Testing (`import Testing`, `@Suite` structs, `#expect`/`#require` macros)
- **Test plan**: `MacAmpApp.xctestplan` (`MacAmpApp.xcodeproj/xcshareddata/xctestplans/MacAmpApp.xctestplan`)
- **Configuration**: Single "All" configuration (simplified from prior 3-config setup)
- **swift-tools-version**: 6.2
- **Total tests**: 137 (across 21 suites)

## Test Tags

Tests are organized with Swift Testing tags defined in `Tests/MacAmpTests/TestTags.swift`:

| Tag | Suites |
|-----|--------|
| `.audio` | LockFreeRingBufferTests, AudioPlayerStateTests |
| `.concurrency` | LockFreeRingBufferConcurrencyTests |
| `.skin` | SkinManagerTests, SpriteResolverTests |
| `.window` | DockGraphTests, ScreenClampTests, WindowFrameStoreTests |
| `.persistence` | AppSettingsTests, WindowFrameStoreTests |
| `.parsing` | EQCodecTests, PlaylistNavigationTests |

## Concurrency-Related Tests

The following suites catch async and thread-safety regressions:

- `AudioPlayerStateTests`: verifies @MainActor playback state transitions for stop/eject.
- `PlaylistNavigationTests`: verifies next/previous playlist actions across local + stream tracks.
- `SkinManagerTests`: verifies async skin loading and error state updates.
- `LockFreeRingBufferConcurrencyTests`: verifies SPSC ring buffer under concurrent write/read, format changes, and high throughput.

All @MainActor-annotated suites catch UI-bound state regressions and async ordering issues.

## Running Tests (CLI)

```bash
swift test                      # whole suite
swift test --filter <SuiteName> # one suite
```

`swift test` runs the unit tests in a plain test process, without launching the app. `xcodebuild test` hosts the test bundle inside `MacAmp.app` and launches it, so it is not used for unit tests.

The tests run alongside whatever the user is doing and must not reach them. `UnitTestSupport.isActive` is true in the test process. Under it the spatial output renderer plays at volume 0, `PlaybackCoordinator` publishes no Now Playing information, and `UnitTestSupport.applicationSupportDirectory` is a throwaway directory instead of the user's Application Support. Gate anything new that would be heard, seen or written on it, and never order a window front or run an alert modally in a test.

## Adding or Updating Tests

1. Add the test file under `Tests/MacAmpTests`.
2. Use `@Suite struct` (not `XCTestCase`) with `import Testing`.
3. Use `@Test` attribute on test functions (not `func test*()` prefix).
4. Use `#expect` / `#require` assertions (not `XCTAssert*`).
5. Apply appropriate tags from `TestTags.swift`.
6. Keep `@MainActor` on suites that touch UI-bound state or SwiftUI models.
7. Add `.timeLimit(.minutes(1))` to async tests.

## References

- `docs/README.md` → Test Plan Quick Reference
- `docs/IMPLEMENTATION_PATTERNS.md` → §7 Testing Patterns
- `docs/MACAMP_ARCHITECTURE_GUIDE.md` → §12 Testing Strategies
