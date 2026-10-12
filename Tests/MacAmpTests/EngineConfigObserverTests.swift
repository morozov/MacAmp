import AVFoundation
import Foundation
import Testing
@testable import MacAmp

@MainActor
@Suite("Engine Configuration Observer", .tags(.audio), .timeLimit(.minutes(1)))
struct EngineConfigObserverTests {

    /// Counts the observer's callbacks. Tests await a count instead of sleeping, so a busy
    /// main actor delays them without failing them.
    @MainActor
    private final class Callbacks {
        private struct Waiter {
            let id: UUID
            let condition: () -> Bool
            let continuation: CheckedContinuation<Void, any Error>
        }

        private(set) var will = 0
        private(set) var did = 0
        private var waiters: [Waiter] = []

        init(_ observer: AudioEngineConfigurationObserver) {
            observer.onWillReconfigure = { [unowned self] in will += 1; resumeWaiters() }
            observer.onDidReconfigure = { [unowned self] in did += 1; resumeWaiters() }
        }

        /// Returns once `condition` holds; throws when the test is cancelled, such as by its time limit.
        /// The waiting test is enqueued on the main actor in the turn that makes `condition` true,
        /// ahead of anything the observer schedules for later.
        func wait(until condition: @escaping () -> Bool) async throws {
            if condition() { return }
            let id = UUID()
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    let waiter = Waiter(id: id, condition: condition, continuation: continuation)
                    if Task.isCancelled {
                        continuation.resume(throwing: CancellationError())
                    } else {
                        waiters.append(waiter)
                    }
                }
            } onCancel: {
                Task { @MainActor in self.cancel(id) }
            }
        }

        private func cancel(_ id: UUID) {
            guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
            waiters.remove(at: index).continuation.resume(throwing: CancellationError())
        }

        private func resumeWaiters() {
            waiters.removeAll { waiter in
                guard waiter.condition() else { return false }
                waiter.continuation.resume()
                return true
            }
        }
    }

    /// Longer than the observer's 150 ms debounce window. Only bounds checks that nothing fires;
    /// a slow run can make them pass late, never fail.
    private static let quietPeriod: Duration = .milliseconds(300)

    private static func post(to engine: AVAudioEngine) {
        NotificationCenter.default.post(name: .AVAudioEngineConfigurationChange, object: engine)
    }

    @Test("Observer fires onWill once and onDid once for a single notification")
    func observerFiresOnSyntheticNotification() async throws {
        let engine = AVAudioEngine()
        let observer = AudioEngineConfigurationObserver(engine: engine)
        let callbacks = Callbacks(observer)
        observer.start()

        Self.post(to: engine)
        try await callbacks.wait { callbacks.did == 1 }
        try await Task.sleep(for: Self.quietPeriod)

        #expect(callbacks.will == 1)
        #expect(callbacks.did == 1)
        observer.stop()
    }

    @Test("Observer collapses a burst of notifications into one will/did pair")
    func observerDebouncesBurst() async throws {
        let engine = AVAudioEngine()
        let observer = AudioEngineConfigurationObserver(engine: engine)
        let callbacks = Callbacks(observer)
        observer.start()

        // Each notification supersedes the in-flight debounce; only the last one
        // ultimately fires onDid.
        for _ in 0..<3 { Self.post(to: engine) }
        try await callbacks.wait { callbacks.did == 1 }
        try await Task.sleep(for: Self.quietPeriod)

        #expect(callbacks.will == 1)
        #expect(callbacks.did == 1)
        observer.stop()
    }

    @Test("stop() during a pending burst cancels onDid; nothing fires later")
    func observerStopDuringBurstCancelsDid() async throws {
        // Documents the contract from commit c454c49: onDid is NOT guaranteed
        // after onWill if stop()/deinit interrupts the debounce window.
        let engine = AVAudioEngine()
        let observer = AudioEngineConfigurationObserver(engine: engine)
        let callbacks = Callbacks(observer)
        observer.start()

        Self.post(to: engine)
        try await callbacks.wait { callbacks.will == 1 }
        #expect(callbacks.did == 0)

        // Tear down mid-burst — pending debounce task must be cancelled.
        observer.stop()

        try await Task.sleep(for: Self.quietPeriod)
        #expect(callbacks.will == 1)
        #expect(callbacks.did == 0)
    }

    @Test("Observer survives multiple start/stop cycles")
    func observerSurvivesStartStopCycles() async throws {
        let engine = AVAudioEngine()
        let observer = AudioEngineConfigurationObserver(engine: engine)
        let callbacks = Callbacks(observer)

        // Cycle 1: start → notification → stop. Should fire one will/did pair.
        observer.start()
        Self.post(to: engine)
        try await callbacks.wait { callbacks.did == 1 }
        observer.stop()
        #expect(callbacks.will == 1)

        // Cycle 2: posting while stopped should be a no-op.
        Self.post(to: engine)
        try await Task.sleep(for: Self.quietPeriod)
        #expect(callbacks.will == 1)
        #expect(callbacks.did == 1)

        // Cycle 3: restart and verify the pair fires again.
        observer.start()
        Self.post(to: engine)
        try await callbacks.wait { callbacks.did == 2 }
        #expect(callbacks.will == 2)
        observer.stop()
    }
}
