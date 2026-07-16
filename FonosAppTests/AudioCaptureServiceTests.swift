import AVFoundation
import Foundation
import Testing
@testable import FonosApp

private final class ControlledAudioCapture: AudioCapturing, @unchecked Sendable {
    private let lock = NSLock()
    private var startCompletion: (@Sendable (Error?) -> Void)?
    private var interruption: (@Sendable () -> Void)?
    private var maximumDurationReached: (@Sendable (Data?) -> Void)?
    private var recording = false
    private var starting = false
    private var stops = 0

    var currentAudioLevel: Float { 0 }
    var isRecording: Bool { lock.withLock { recording } }
    var isStarting: Bool { lock.withLock { starting } }
    var stopCount: Int { lock.withLock { stops } }

    func micPermissionStatus() -> AVAudioSession.RecordPermission {
        guard let permission = AVAudioSession.RecordPermission(rawValue: 0x6772_6E74) else {
            preconditionFailure("Unexpected test record-permission value")
        }
        return permission
    }
    func requestMicPermission() async -> Bool { true }

    @discardableResult
    func startCapture(
        onInterruption: @escaping @Sendable () -> Void,
        onMaximumDurationReached: @escaping @Sendable (Data?) -> Void,
        completion: @escaping @Sendable (Error?) -> Void
    ) -> AudioCaptureStartToken {
        lock.withLock {
            starting = true
            self.interruption = onInterruption
            self.maximumDurationReached = onMaximumDurationReached
            startCompletion = completion
        }
        // Tests only need identity opacity; production creates the real token.
        return AudioCaptureStartToken()
    }

    func completeStart(error: Error? = nil) {
        let completion = lock.withLock { () -> (@Sendable (Error?) -> Void)? in
            if error == nil {
                recording = true
            }
            starting = false
            return startCompletion
        }
        completion?(error)
    }

    @MainActor
    @discardableResult
    func stopCapture() -> Data? {
        lock.withLock {
            stops += 1
            starting = false
            recording = false
        }
        return nil
    }

    @MainActor
    func triggerInterruption() {
        let callback = lock.withLock { interruption }
        _ = stopCapture()
        callback?()
    }

    func triggerMaximumDurationReached(wavData: Data?) {
        let callback = lock.withLock { () -> (@Sendable (Data?) -> Void)? in
            recording = false
            return maximumDurationReached
        }
        callback?(wavData)
    }
}

@MainActor
private func yieldToMainQueue() async {
    await withCheckedContinuation { continuation in
        DispatchQueue.main.async {
            continuation.resume()
        }
    }
}

struct AudioCaptureServiceTests {
    @Test("foreground microphone lease permits only one AudioCaptureService owner")
    func foregroundMicrophoneLeaseIsExclusive() {
        let registry = ForegroundAudioCaptureLeaseRegistry()
        let first = AudioCaptureStartToken()
        let second = AudioCaptureStartToken()

        #expect(registry.acquire(first))
        #expect(!registry.acquire(second))
        registry.release(second)
        #expect(!registry.acquire(second), "A non-owner must not release the active lease")
        registry.release(first)
        #expect(registry.acquire(second))
        registry.release(second)
    }

    @Test("Foreground capture is bounded at five minutes without a 60-second ring")
    func foregroundCapturePolicyIsFiveMinutes() {
        #expect(AudioCapturePolicy.maximumDuration == 5 * 60)
        #expect(AudioCapturePolicy.maximumSamples == 16_000 * 5 * 60)
        #expect(AudioCapturePolicy.acceptedSampleCount(
            currentCount: AudioCapturePolicy.maximumSamples - 2,
            incomingCount: 4
        ) == 2)
        #expect(AudioCapturePolicy.acceptedSampleCount(
            currentCount: AudioCapturePolicy.maximumSamples,
            incomingCount: 4
        ) == 0)
    }

    @Test("A rapid stop cancels a pending start and ignores its late completion")
    @MainActor
    func rapidStartStopCannotResurrectRecording() async {
        let capture = ControlledAudioCapture()
        let viewModel = DictationViewModel(
            sttProvider: nil,
            audioCapture: capture
        )

        viewModel.startRecording()
        #expect(viewModel.recordingState == .starting)
        #expect(!viewModel.isRecording)

        viewModel.stopRecording()
        #expect(viewModel.recordingState == .idle)
        #expect(capture.stopCount == 1)

        capture.completeStart()
        await yieldToMainQueue()
        #expect(viewModel.recordingState == .idle)
        #expect(!viewModel.isRecording)
    }

    @Test("UI enters recording only after the audio backend commits start")
    @MainActor
    func recordingStateFollowsRealStart() async {
        let capture = ControlledAudioCapture()
        let viewModel = DictationViewModel(
            sttProvider: nil,
            audioCapture: capture
        )

        viewModel.startRecording()
        #expect(viewModel.recordingState == .starting)
        #expect(viewModel.workflowPresentation.nodes.allSatisfy {
            $0.state == .pending
        })

        capture.completeStart()
        await yieldToMainQueue()
        #expect(viewModel.recordingState == .recording)
        #expect(viewModel.isRecording)
        #expect(viewModel.workflowPresentation.nodes.first?.state == .running)
    }

    @Test("Audio interruption stops capture and leaves an actionable UI error")
    @MainActor
    func interruptionIsNotSilent() async {
        let capture = ControlledAudioCapture()
        let viewModel = DictationViewModel(
            sttProvider: nil,
            audioCapture: capture
        )
        viewModel.startRecording()
        capture.completeStart()
        await yieldToMainQueue()
        #expect(viewModel.recordingState == .recording)

        capture.triggerInterruption()
        await yieldToMainQueue()

        guard case .error(let message) = viewModel.recordingState else {
            Issue.record("Expected an interruption error")
            return
        }
        #expect(message.contains("interrupted"))
        #expect(!capture.isRecording)
        #expect(capture.stopCount == 1)
    }

    @Test("Automatic duration finalization failure leaves an explicit UI error")
    @MainActor
    func durationLimitFailureIsNotSilent() async {
        let capture = ControlledAudioCapture()
        let viewModel = DictationViewModel(
            sttProvider: nil,
            audioCapture: capture
        )
        viewModel.startRecording()
        capture.completeStart()
        await yieldToMainQueue()
        #expect(viewModel.recordingState == .recording)

        capture.triggerMaximumDurationReached(wavData: nil)
        await yieldToMainQueue()

        guard case .error(let message) = viewModel.recordingState else {
            Issue.record("Expected a duration-limit finalization error")
            return
        }
        #expect(message.contains("five-minute limit"))
        #expect(!capture.isRecording)
    }
}
