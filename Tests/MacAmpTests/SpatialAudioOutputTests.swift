import Testing
import Foundation
import AVFoundation
@testable import MacAmp

@Suite("SpatialAudioOutput integration", .tags(.audio), .serialized)
@MainActor
struct SpatialAudioOutputTests {

    private func makeToneFile(seconds: Double = 20, sampleRate sr: Double = 44_100) throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("macamp_spatial_test_tone_\(Int(seconds))_\(Int(sr)).wav")
        if FileManager.default.fileExists(atPath: url.path) { return url }
        let fmt = AVAudioFormat(standardFormatWithSampleRate: sr, channels: 2)!
        let file = try AVAudioFile(forWriting: url, settings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sr,
            AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ])
        let total = Int(seconds * sr), chunk = 4096
        var pL = 0.0, pR = 0.0, written = 0
        while written < total {
            let n = min(chunk, total - written)
            let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(n))!
            buf.frameLength = AVAudioFrameCount(n)
            let L = buf.floatChannelData![0], R = buf.floatChannelData![1]
            let sL = 2 * Double.pi * 220 / sr, sR = 2 * Double.pi * 330 / sr
            for i in 0..<n { L[i] = 0.15 * Float(sin(pL)); R[i] = 0.15 * Float(sin(pR)); pL += sL; pR += sR }
            try file.write(from: buf)
            written += n
        }
        return url
    }

    @Test("Recovery from an underrun enqueues no past-PTS buffers (no catch-up speed-up)")
    func noPastPTSAfterUnderrun() async throws {
        let url = try makeToneFile()  // 20s, long enough to avoid EOF
        let eq = EqualizerController()
        let viz = VisualizerPipeline()
        let engine = AudioEngineController(eqNode: eq.eqNode, visualizerPipeline: viz)
        try engine.loadFile(url: url)
        #expect(engine.scheduleFrom(time: 0, seekID: UUID()))
        engine.playAudio()
        try await Task.sleep(nanoseconds: 700_000_000)
        #expect(engine.spatialOutput.pastPTSEnqueues == 0)  // none during normal play

        // Underrun: the clock runs on past what was produced.
        let heard = engine.currentPlaybackSeconds + engine.spatialOutput.leadSeconds
        engine.spatialOutput.suspendFeed()
        try await Task.sleep(nanoseconds: 2_500_000_000)
        #expect(engine.spatialOutput.leadSeconds < -0.5)  // frontier now behind the clock

        let resumedAt = Date()
        engine.spatialOutput.ensureFeeding()
        try await Task.sleep(nanoseconds: 400_000_000)
        #expect(engine.spatialOutput.pastPTSEnqueues == 0)
        // The file resumes where the audio ran out, not where the clock went on to.
        let position = engine.currentPlaybackSeconds
        let expected = heard + Date().timeIntervalSince(resumedAt)
        #expect(abs(position - expected) < 0.15, "position \(position) s, expected \(expected) s")
        engine.shutdown()
    }

    @Test("The feed keeps ahead of the clock beyond the initial burst")
    func feedSustains() async throws {
        let url = try makeToneFile()
        let eq = EqualizerController()
        let viz = VisualizerPipeline()
        let engine = AudioEngineController(eqNode: eq.eqNode, visualizerPipeline: viz)
        try engine.loadFile(url: url)
        #expect(engine.scheduleFrom(time: 0, seekID: UUID()))
        engine.playAudio()

        try await Task.sleep(nanoseconds: 5_000_000_000)
        #expect(engine.currentPlaybackSeconds > 2.5)
        // Five seconds in, well past any initial burst.
        #expect(engine.spatialOutput.leadSeconds > 0)
        engine.shutdown()
    }

    @Test("End of track fires once the end is heard")
    func completionFiresAtEnd() async throws {
        let url = try makeToneFile(seconds: 1)
        let eq = EqualizerController()
        let viz = VisualizerPipeline()
        let engine = AudioEngineController(eqNode: eq.eqNode, visualizerPipeline: viz)

        var endedAt: Double?
        engine.onPlaybackEnded = { _ in endedAt = engine.currentPlaybackSeconds }
        try engine.loadFile(url: url)
        #expect(engine.scheduleFrom(time: 0, seekID: UUID()))
        engine.playAudio()
        engine.startProgressTimer()

        try await Task.sleep(nanoseconds: 3_500_000_000)
        let position = try #require(endedAt)
        #expect(position >= 1.0, "ended at \(position) s, before the end was heard")
        engine.shutdown()
    }

    @Test("PTS clamp never fires during normal playback (no PTS gaps)")
    func noPtsClampDuringNormalPlay() async throws {
        // A clamp in steady state leaves a PTS gap the renderer fills with silence.
        let url = try makeToneFile()
        let eq = EqualizerController()
        let viz = VisualizerPipeline()
        let engine = AudioEngineController(eqNode: eq.eqNode, visualizerPipeline: viz)
        try engine.loadFile(url: url)
        #expect(engine.scheduleFrom(time: 0, seekID: UUID()))
        engine.playAudio()
        try await Task.sleep(nanoseconds: 4_000_000_000)  // 4s — past the 100-buffer skip window
        #expect(engine.spatialOutput.ptsClampsFired == 0,
                "clamp fired \(engine.spatialOutput.ptsClampsFired) time(s) during normal play — PTS gap(s) introduced")
        engine.shutdown()
    }

    @Test("Renderer is not auto-flushed during normal playback")
    func noAutoFlushDuringPlay() async throws {
        let url = try makeToneFile()
        let eq = EqualizerController()
        let viz = VisualizerPipeline()
        let engine = AudioEngineController(eqNode: eq.eqNode, visualizerPipeline: viz)
        try engine.loadFile(url: url)
        #expect(engine.scheduleFrom(time: 0, seekID: UUID()))
        engine.playAudio()
        try await Task.sleep(nanoseconds: 3_000_000_000)
        #expect(engine.spatialOutput.autoFlushCountSeam == 0,
                "renderer was auto-flushed \(engine.spatialOutput.autoFlushCountSeam) time(s) during playback")
        engine.shutdown()
    }

    @Test("Clock starts advancing within 500ms of playAudio (no excessive startup delay)")
    func clockStartsPromptly() async throws {
        let url = try makeToneFile()
        let eq = EqualizerController()
        let viz = VisualizerPipeline()
        let engine = AudioEngineController(eqNode: eq.eqNode, visualizerPipeline: viz)
        try engine.loadFile(url: url)
        #expect(engine.scheduleFrom(time: 0, seekID: UUID()))
        engine.playAudio()
        let startWall = Date()
        var clockStarted = false
        for _ in 0..<50 {  // poll for up to 500ms
            try await Task.sleep(nanoseconds: 10_000_000)
            if engine.currentPlaybackSeconds > 0.001 {
                clockStarted = true
                break
            }
        }
        let elapsed = Date().timeIntervalSince(startWall)
        #expect(clockStarted, "clock never started after 500ms")
        #expect(elapsed < 0.500,
                "clock took \(String(format:"%.0f", elapsed * 1000))ms to start — startup delay too long")
        engine.shutdown()
    }

    @Test("The audible clock advances throughout playback")
    func clockAdvancesDuringPlayback() async throws {
        let url = try makeToneFile()
        let eq = EqualizerController()
        let viz = VisualizerPipeline()
        let engine = AudioEngineController(eqNode: eq.eqNode, visualizerPipeline: viz)
        try engine.loadFile(url: url)
        #expect(engine.scheduleFrom(time: 0, seekID: UUID()))
        engine.playAudio()

        try await Task.sleep(nanoseconds: 300_000_000)

        let sampleInterval: UInt64 = 10_000_000  // 10ms
        let samples = 200  // 2 seconds of sampling
        var prev = engine.currentPlaybackSeconds
        for _ in 0..<samples {
            try await Task.sleep(nanoseconds: sampleInterval)
            let now = engine.currentPlaybackSeconds
            #expect(now > prev,
                    "clock stalled: position did not advance (prev=\(prev) now=\(now))")
            prev = now
        }
        engine.shutdown()
    }

    @Test("No silence buffers enqueued during play start")
    func noSilenceAtPlayStart() async throws {
        let url = try makeToneFile()
        let eq = EqualizerController()
        let viz = VisualizerPipeline()
        let engine = AudioEngineController(eqNode: eq.eqNode, visualizerPipeline: viz)
        try engine.loadFile(url: url)
        #expect(engine.scheduleFrom(time: 0, seekID: UUID()))
        engine.playAudio()
        try await Task.sleep(nanoseconds: 400_000_000)
        #expect(engine.spatialOutput.minBufferPeak > 0.01,
                "silence buffer enqueued at play start (minPeak=\(engine.spatialOutput.minBufferPeak)); feed started before playerNode was playing")
        engine.shutdown()
    }

    @Test("No silence buffers enqueued after seek")
    func noSilenceAfterSeek() async throws {
        let url = try makeToneFile()
        let eq = EqualizerController()
        let viz = VisualizerPipeline()
        let engine = AudioEngineController(eqNode: eq.eqNode, visualizerPipeline: viz)
        try engine.loadFile(url: url)
        #expect(engine.scheduleFrom(time: 0, seekID: UUID()))
        engine.playAudio()
        try await Task.sleep(nanoseconds: 400_000_000)

        #expect(engine.scheduleFrom(time: 5, seekID: UUID()))
        engine.playAudio()
        try await Task.sleep(nanoseconds: 400_000_000)
        #expect(engine.spatialOutput.minBufferPeak > 0.01,
                "silence buffer enqueued after seek (minPeak=\(engine.spatialOutput.minBufferPeak)); feed started before playerNode was playing")
        engine.shutdown()
    }

    @Test("Rescheduling without a seek, as consecutive CUE slices do, enqueues no silence")
    func noSilenceAfterInPlaceReschedule() async throws {
        let url = try makeToneFile()
        let eq = EqualizerController()
        let viz = VisualizerPipeline()
        let engine = AudioEngineController(eqNode: eq.eqNode, visualizerPipeline: viz)
        try engine.loadFile(url: url)
        #expect(engine.scheduleFrom(time: 0, seekID: UUID()))
        engine.playAudio()
        try await Task.sleep(nanoseconds: 400_000_000)

        #expect(engine.scheduleFrom(time: 5, endTime: 15, seekID: UUID()))
        try await Task.sleep(nanoseconds: 300_000_000)
        engine.playAudio()
        try await Task.sleep(nanoseconds: 400_000_000)
        #expect(engine.spatialOutput.minBufferPeak > 0.01)
        engine.shutdown()
    }

    @Test("Stop, then play, enqueues no silence")
    func noSilenceAfterStopThenPlay() async throws {
        let url = try makeToneFile()
        let eq = EqualizerController()
        let viz = VisualizerPipeline()
        let engine = AudioEngineController(eqNode: eq.eqNode, visualizerPipeline: viz)
        try engine.loadFile(url: url)
        #expect(engine.scheduleFrom(time: 0, seekID: UUID()))
        engine.playAudio()
        try await Task.sleep(nanoseconds: 400_000_000)

        // AudioPlayer.stop(): stopAudio, then reschedule from the top.
        engine.stopAudio()
        #expect(engine.scheduleFrom(time: 0, seekID: UUID()))
        try await Task.sleep(nanoseconds: 500_000_000)
        engine.playAudio()
        try await Task.sleep(nanoseconds: 400_000_000)
        #expect(engine.spatialOutput.minBufferPeak > 0.01)
        engine.shutdown()
    }

    @Test("Audio has no holes after start and after seeks", arguments: [44_100.0, 96_000.0, 192_000.0])
    func noHolesAcrossSeeks(sampleRate: Double) async throws {
        let url = try makeToneFile(sampleRate: sampleRate)
        let eq = EqualizerController()
        let viz = VisualizerPipeline()
        let engine = AudioEngineController(eqNode: eq.eqNode, visualizerPipeline: viz)
        try engine.loadFile(url: url)
        #expect(engine.scheduleFrom(time: 0, seekID: UUID()))
        engine.playAudio()
        try await Task.sleep(nanoseconds: 2_500_000_000)
        #expect(engine.spatialOutput.gapRuns == 0, "holes after start")

        for target in [8.0, 3.0, 12.0] {
            #expect(engine.scheduleFrom(time: target, seekID: UUID()))
            engine.playAudio()
            try await Task.sleep(nanoseconds: 2_500_000_000)
            #expect(engine.spatialOutput.gapRuns == 0, "holes after seeking to \(target) s")
        }
        engine.shutdown()
    }

    @Test("Seeking while playing hands over to the other renderer without a full flush")
    func seekHandsOverWithoutFlush() async throws {
        let url = try makeToneFile()
        let eq = EqualizerController()
        let viz = VisualizerPipeline()
        let engine = AudioEngineController(eqNode: eq.eqNode, visualizerPipeline: viz)
        try engine.loadFile(url: url)
        #expect(engine.scheduleFrom(time: 0, seekID: UUID()))
        engine.playAudio()
        try await Task.sleep(nanoseconds: 1_000_000_000)

        for (round, target) in [8.0, 3.0, 12.0].enumerated() {
            let seekedAt = Date()
            #expect(engine.scheduleFrom(time: target, seekID: UUID()))
            #expect(engine.currentPlaybackSeconds == target, "position before the new audio starts")
            engine.playAudio()
            try await Task.sleep(nanoseconds: 1_000_000_000)
            #expect(engine.spatialOutput.switches == round + 1)
            let elapsed = Date().timeIntervalSince(seekedAt)
            let position = engine.currentPlaybackSeconds
            #expect(position > target + elapsed - 0.5 && position <= target + elapsed,
                    "position \(position) s, \(elapsed) s after seeking to \(target) s")
            #expect(engine.spatialOutput.gapRuns == 0, "holes after seeking to \(target) s")
        }
        #expect(engine.spatialOutput.cutFallbacks == 0)
        #expect(engine.spatialOutput.ptsClampsFired == 0)
        engine.shutdown()
    }

    @Test("Rapid seeks land on the last target without holes")
    func rapidSeeks() async throws {
        let url = try makeToneFile()
        let eq = EqualizerController()
        let viz = VisualizerPipeline()
        let engine = AudioEngineController(eqNode: eq.eqNode, visualizerPipeline: viz)
        try engine.loadFile(url: url)
        #expect(engine.scheduleFrom(time: 0, seekID: UUID()))
        engine.playAudio()
        try await Task.sleep(nanoseconds: 1_000_000_000)

        var seekedAt = Date()
        for target in [4.0, 9.0, 14.0] {
            seekedAt = Date()
            #expect(engine.scheduleFrom(time: target, seekID: UUID()))
            engine.playAudio()
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        try await Task.sleep(nanoseconds: 1_500_000_000)
        let elapsed = Date().timeIntervalSince(seekedAt)
        let position = engine.currentPlaybackSeconds
        #expect(position > 14 + elapsed - 0.5 && position <= 14 + elapsed,
                "position \(position) s, \(elapsed) s after seeking to 14 s")
        #expect(engine.spatialOutput.gapRuns == 0)
        #expect(engine.spatialOutput.cutFallbacks == 0)
        #expect(!engine.spatialOutput.isHoldingMuteForTail)
        engine.shutdown()
    }

    @Test("A renderer taken back before its muted tail ends stays muted until the tail plays out")
    func handBackHoldsMuteUntilTailEnds() async throws {
        let url = try makeToneFile()
        let eq = EqualizerController()
        let viz = VisualizerPipeline()
        let engine = AudioEngineController(eqNode: eq.eqNode, visualizerPipeline: viz)
        try engine.loadFile(url: url)
        #expect(engine.scheduleFrom(time: 0, seekID: UUID()))
        engine.playAudio()
        try await Task.sleep(nanoseconds: 1_000_000_000)

        // Cut renderer A 1.5 s ahead, then hand back to it while that tail plays.
        engine.spatialOutput.setCutLeadFloorForTesting(1.5)
        #expect(engine.scheduleFrom(time: 5, seekID: UUID()))
        let queued = engine.spatialOutput.enqueuedCount
        engine.playAudio()
        while engine.spatialOutput.enqueuedCount == queued {
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        #expect(engine.scheduleFrom(time: 10, seekID: UUID()))
        engine.playAudio()
        #expect(engine.spatialOutput.switches == 2)
        #expect(engine.spatialOutput.isHoldingMuteForTail)

        try await Task.sleep(nanoseconds: 2_000_000_000)
        #expect(!engine.spatialOutput.isHoldingMuteForTail)
        #expect(engine.spatialOutput.cutFallbacks == 0)
        engine.shutdown()
    }

    @Test("A renderer refilled after an output change keeps its muted tail when it goes idle")
    func recoveredRendererKeepsTailWhenIdle() async throws {
        let url = try makeToneFile()
        let eq = EqualizerController()
        let viz = VisualizerPipeline()
        let engine = AudioEngineController(eqNode: eq.eqNode, visualizerPipeline: viz)
        try engine.loadFile(url: url)
        #expect(engine.scheduleFrom(time: 0, seekID: UUID()))
        engine.playAudio()
        try await Task.sleep(nanoseconds: 1_000_000_000)

        // With the feed idle, only the refill puts audio back into renderer A.
        engine.spatialOutput.suspendFeed()
        NotificationCenter.default.post(
            name: NSNotification.Name("AVSampleBufferAudioRendererOutputConfigurationDidChangeNotification"),
            object: engine.spatialOutput.rendererForTesting
        )
        try await Task.sleep(nanoseconds: 300_000_000)

        // Cut the refilled renderer A far ahead. Playing again warms the idle renderer,
        // which must not end A's muted tail earlier, or a hand-back unmutes it mid-tail.
        engine.spatialOutput.setCutLeadFloorForTesting(1.5)
        #expect(engine.scheduleFrom(time: 5, seekID: UUID()))
        let tail = engine.spatialOutput.idleTailEnd
        let queued = engine.spatialOutput.enqueuedCount
        engine.playAudio()
        while engine.spatialOutput.enqueuedCount == queued {
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        #expect(engine.spatialOutput.idleTailEnd >= tail)
        engine.shutdown()
    }

    @Test("A flush re-enqueues buffered audio from the audible position")
    func flushKeepsBufferedAudio() async throws {
        let url = try makeToneFile()
        let eq = EqualizerController()
        let viz = VisualizerPipeline()
        let engine = AudioEngineController(eqNode: eq.eqNode, visualizerPipeline: viz)
        try engine.loadFile(url: url)
        #expect(engine.scheduleFrom(time: 0, seekID: UUID()))
        engine.playAudio()
        try await Task.sleep(nanoseconds: 1_500_000_000)

        NotificationCenter.default.post(
            name: NSNotification.Name("AVSampleBufferAudioRendererOutputConfigurationDidChangeNotification"),
            object: engine.spatialOutput.rendererForTesting
        )
        try await Task.sleep(nanoseconds: 300_000_000)

        let offset = try #require(engine.spatialOutput.firstRefillOffset)
        #expect(offset >= -0.001 && offset < 0.01, "refill started \(offset) s from the audible clock")
        try await Task.sleep(nanoseconds: 1_000_000_000)
        #expect(engine.spatialOutput.gapRuns == 0)
        #expect(engine.spatialOutput.pastPTSEnqueues == 0)
        engine.shutdown()
    }

    @Test("An active stream bridge produces output")
    func streamBridgeProducesOutput() async throws {
        let eq = EqualizerController()
        let viz = VisualizerPipeline()
        let engine = AudioEngineController(eqNode: eq.eqNode, visualizerPipeline: viz)
        let ring = LockFreeRingBuffer(capacity: 480_000, channelCount: 2)
        let frames = 96_000
        var tone = [Float](repeating: 0, count: frames * 2)
        for i in 0..<frames {
            let v = 0.15 * Float(sin(2 * Double.pi * 220 * Double(i) / 48_000))
            tone[i * 2] = v
            tone[i * 2 + 1] = v
        }
        _ = tone.withUnsafeBufferPointer { ring.write(from: $0.baseAddress!, frameCount: frames) }

        engine.activateStreamBridge(ringBuffer: ring, sampleRate: 48_000)
        try await Task.sleep(nanoseconds: 800_000_000)
        #expect(engine.spatialOutput.enqueuedCount > 0)
        #expect(engine.currentPlaybackSeconds > 0.3)

        engine.setStreamSilenced(true)
        #expect(engine.spatialOutput.bufferedAheadSeconds == 0)
        let held = engine.currentPlaybackSeconds
        try await Task.sleep(nanoseconds: 300_000_000)
        #expect(engine.currentPlaybackSeconds == held)

        engine.setStreamSilenced(false)
        try await Task.sleep(nanoseconds: 300_000_000)
        #expect(engine.currentPlaybackSeconds > held + 0.1)

        engine.deactivateStreamBridge()
        #expect(engine.spatialOutput.bufferedAheadSeconds == 0)
        engine.shutdown()
    }

    @Test("A stream started on a one-second prebuffer and fed in real time has no holes")
    func streamPacedProductionHasNoHoles() async throws {
        let eq = EqualizerController()
        let viz = VisualizerPipeline()
        let engine = AudioEngineController(eqNode: eq.eqNode, visualizerPipeline: viz)
        let rate = 48_000.0
        let ring = LockFreeRingBuffer(capacity: 480_000, channelCount: 2)
        var phase = 0.0
        func produce(seconds: Double) {
            let frames = Int(seconds * rate)
            var pcm = [Float](repeating: 0, count: frames * 2)
            for i in 0..<frames {
                let v = 0.15 * Float(sin(phase))
                pcm[i * 2] = v
                pcm[i * 2 + 1] = v
                phase += 2 * Double.pi * 220 / rate
            }
            _ = pcm.withUnsafeBufferPointer { ring.write(from: $0.baseAddress!, frameCount: frames) }
        }

        produce(seconds: 1)
        engine.activateStreamBridge(ringBuffer: ring, sampleRate: rate)
        // Deliver at exactly the playback rate, as a steady network would.
        let start = Date()
        var delivered = 0.0
        while Date().timeIntervalSince(start) < 3 {
            try await Task.sleep(nanoseconds: 20_000_000)
            let due = Date().timeIntervalSince(start) - delivered
            produce(seconds: due)
            delivered += due
        }
        #expect(engine.spatialOutput.gapRuns == 0)
        #expect(engine.spatialOutput.minBufferPeak > 0.01)
        #expect(engine.currentPlaybackSeconds > 2.5)
        engine.shutdown()
    }

    @Test("A stream outage that drains the output enters rebuffering and holds until it clears")
    func streamOutageRebuffers() async throws {
        let eq = EqualizerController()
        let viz = VisualizerPipeline()
        let engine = AudioEngineController(eqNode: eq.eqNode, visualizerPipeline: viz)
        let rate = 48_000.0
        let ring = LockFreeRingBuffer(capacity: 480_000, channelCount: 2)
        var phase = 0.0
        func produce(seconds: Double) {
            let frames = Int(seconds * rate)
            var pcm = [Float](repeating: 0, count: frames * 2)
            for i in 0..<frames {
                let v = 0.15 * Float(sin(phase))
                pcm[i * 2] = v
                pcm[i * 2 + 1] = v
                phase += 2 * Double.pi * 220 / rate
            }
            _ = pcm.withUnsafeBufferPointer { ring.write(from: $0.baseAddress!, frameCount: frames) }
        }

        produce(seconds: 1)
        engine.activateStreamBridge(ringBuffer: ring, sampleRate: rate)
        // Nothing more arrives: the output plays out what it has, then starves.
        try await Task.sleep(nanoseconds: 3_000_000_000)
        #expect(ring.isRebuffering, "an outage that drained the output was not reported")

        // A trickle below the refill threshold must not restart output.
        let enqueued = engine.spatialOutput.enqueuedCount
        produce(seconds: 0.1)
        try await Task.sleep(nanoseconds: 300_000_000)
        #expect(engine.spatialOutput.enqueuedCount == enqueued)

        // Once the decode side clears the flag, output resumes without holes.
        produce(seconds: 1)
        ring.setRebuffering(false)
        try await Task.sleep(nanoseconds: 300_000_000)
        #expect(engine.spatialOutput.enqueuedCount > enqueued)
        #expect(engine.spatialOutput.gapRuns == 0)
        engine.shutdown()
    }

    @Test("A starvation report never leaves rebuffering set over a ring that holds enough")
    func starvationReportRechecksTheRing() {
        let ring = LockFreeRingBuffer(capacity: 96_000, channelCount: 2)
        let second = [Float](repeating: 0.1, count: 48_000 * 2)

        AudioEngineController.reportStarvation(of: ring, below: 4096)
        #expect(ring.isRebuffering)

        // The decoder refilled and cleared the flag after the feed saw the
        // ring short: a late report must not set it again.
        _ = second.withUnsafeBufferPointer { ring.write(from: $0.baseAddress!, frameCount: 48_000) }
        ring.setRebuffering(false)
        AudioEngineController.reportStarvation(of: ring, below: 4096)
        #expect(!ring.isRebuffering)
    }

    @Test("Plays a local file through manual-rendering spatial output, seeks, and stops")
    func playsSeeksStops() async throws {
        let url = try makeToneFile()

        let eq = EqualizerController()
        let viz = VisualizerPipeline()
        let engine = AudioEngineController(eqNode: eq.eqNode, visualizerPipeline: viz)

        try engine.loadFile(url: url)
        #expect(engine.scheduleFrom(time: 0, seekID: UUID()))
        engine.playAudio()

        try await Task.sleep(nanoseconds: 800_000_000)
        #expect(engine.isEngineRunning)
        #expect(engine.spatialOutput.enqueuedCount > 0)
        let posAfterPlay = engine.currentPlaybackSeconds
        #expect(posAfterPlay > 0.3 && posAfterPlay < 1.5)

        #expect(engine.scheduleFrom(time: 10, seekID: UUID()))
        try await Task.sleep(nanoseconds: 300_000_000)
        #expect(engine.isEngineRunning)
        let posAfterSeek = engine.currentPlaybackSeconds
        #expect(posAfterSeek > 9.5 && posAfterSeek < 11.5)

        engine.pauseAudio()
        engine.stopAudio()
        engine.shutdown()
    }

    @Test("No output-config-change notifications during clean playback")
    func noOutputConfigChangeDuringPlay() async throws {
        let url = try makeToneFile()
        let eq = EqualizerController()
        let viz = VisualizerPipeline()
        let engine = AudioEngineController(eqNode: eq.eqNode, visualizerPipeline: viz)
        try engine.loadFile(url: url)
        #expect(engine.scheduleFrom(time: 0, seekID: UUID()))
        engine.playAudio()
        try await Task.sleep(nanoseconds: 3_000_000_000)
        #expect(engine.spatialOutput.outputConfigChanges == 0,
                "output-config-change fired \(engine.spatialOutput.outputConfigChanges) time(s) during clean playback — renderer requires flush+re-enqueue on each fire")
        engine.shutdown()
    }

    @Test("Playback continues cleanly after a simulated output-config change")
    func recoversAfterOutputConfigChange() async throws {
        let url = try makeToneFile()
        let eq = EqualizerController()
        let viz = VisualizerPipeline()
        let engine = AudioEngineController(eqNode: eq.eqNode, visualizerPipeline: viz)
        try engine.loadFile(url: url)
        #expect(engine.scheduleFrom(time: 0, seekID: UUID()))
        engine.playAudio()

        try await Task.sleep(nanoseconds: 800_000_000)
        let posBefore = engine.currentPlaybackSeconds
        #expect(posBefore > 0.3, "playback did not start before config-change simulation")

        NotificationCenter.default.post(
            name: NSNotification.Name("AVSampleBufferAudioRendererOutputConfigurationDidChangeNotification"),
            object: engine.spatialOutput.rendererForTesting
        )

        try await Task.sleep(nanoseconds: 1_000_000_000)

        #expect(engine.spatialOutput.outputConfigChanges == 1,
                "expected exactly 1 config-change event, got \(engine.spatialOutput.outputConfigChanges)")
        let posAfter = engine.currentPlaybackSeconds
        #expect(posAfter > posBefore,
                "clock stalled after output-config-change flush (before=\(posBefore) after=\(posAfter))")
        engine.shutdown()
    }
}
