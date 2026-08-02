import Testing
import Foundation
@testable import MacAmp

/// The playback-progress guard skips the observable `currentTime`/`playbackProgress`
/// write when the *displayed* value is unchanged, cutting re-renders from the
/// 10 Hz timer to the rate the readouts actually change. These assert the guard
/// buckets losslessly — the same second and the same screen pixel are shown.
@MainActor
@Suite("Playback progress guard", .tags(.audio))
struct ProgressGuardTests {

    @Test("displaySecond buckets to whole seconds")
    func displaySecondBuckets() {
        #expect(AudioPlayer.displaySecond(0) == 0)
        #expect(AudioPlayer.displaySecond(0.99) == 0)
        #expect(AudioPlayer.displaySecond(4.99) == 4)
        #expect(AudioPlayer.displaySecond(5.0) == 5)
        // Sub-second changes stay in one bucket, so the guard skips them while
        // the readout still shows the same "0:05".
        #expect(AudioPlayer.displaySecond(5.1) == AudioPlayer.displaySecond(5.9))
    }

    @Test("thumbStep maps progress across the seek travel, monotonically")
    func thumbStepMaps() {
        #expect(AudioPlayer.thumbStep(0) == 0)
        #expect(AudioPlayer.thumbStep(1.0) == 876)      // (248 − 29) pt × 4 steps/pt
        #expect(AudioPlayer.thumbStep(0.5) == 438)
        // Monotonic across the range.
        var previous = -1
        for i in 0...1000 {
            let step = AudioPlayer.thumbStep(Double(i) / 1000)
            #expect(step >= previous)
            previous = step
        }
    }

    /// The guard's buckets must be at least as fine as the grid the thumb draws
    /// on, or a step the thumb would have taken is never published.
    @Test("every drawable thumb pixel gets its own bucket")
    func thumbStepCoversEveryDrawnPixel() {
        for pixelsPerPoint in [1.0, 2.0, 4.0] as [Double] {
            let pixels = Int((248.0 - 29.0) * pixelsPerPoint)
            // Sample the middle of each pixel; a boundary sample would only be
            // testing which side of it floating point rounds to.
            let buckets = (0..<pixels).map {
                AudioPlayer.thumbStep((Double($0) + 0.5) / Double(pixels))
            }
            #expect(Set(buckets).count == pixels)
        }
    }
}
