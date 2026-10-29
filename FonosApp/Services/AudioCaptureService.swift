import Foundation
import AVFoundation
import os.log

let audioCaptureLog = Logger(subsystem: "com.fonos.ios", category: "AudioCapture")

final class AudioCaptureConverterInput: @unchecked Sendable {
    let buffer: AVAudioPCMBuffer
    var wasProvided = false

    init(buffer: AVAudioPCMBuffer) {
        self.buffer = buffer
    }

    func next(
        status: UnsafeMutablePointer<AVAudioConverterInputStatus>
    ) -> AVAudioBuffer? {
        guard !wasProvided else {
            status.pointee = .noDataNow
            return nil
        }
        wasProvided = true
        status.pointee = .haveData
        return buffer
    }
}

// MARK: - Errors

enum AudioCaptureError: Error, LocalizedError {
    case engineStartFailed(Error)
    case sessionSetupFailed(Error)
    case permissionDenied
    case noInputAvailable
    case notRecording
    case captureAlreadyActive
    case startCancelled

    var errorDescription: String? {
        switch self {
        case .engineStartFailed(let err): return "Audio engine failed to start: \(err.localizedDescription)"
        case .sessionSetupFailed(let err): return "Audio session setup failed: \(err.localizedDescription)"
        case .permissionDenied: return "Microphone permission is required. Please enable it in Settings."
        case .noInputAvailable: return "No audio input available"
        case .notRecording: return "Not currently recording"
        case .captureAlreadyActive: return "Another Fonos recording is already starting or active"
        case .startCancelled: return "Audio capture start was cancelled"
        }
    }
}

enum AudioCapturePolicy {
    static let maximumDuration: TimeInterval = 5 * 60
    static let sampleRate = 16_000
    static let maximumSamples = sampleRate * Int(maximumDuration)

    static func acceptedSampleCount(
        currentCount: Int,
        incomingCount: Int
    ) -> Int {
        min(max(0, maximumSamples - currentCount), max(0, incomingCount))
    }
}

enum WAVError: Error, LocalizedError {
    case invalidData
    case unsupportedFormat
    case bufferCreationFailed

    var errorDescription: String? {
        switch self {
        case .invalidData: return "WAV data is invalid or too short"
        case .unsupportedFormat: return "WAV format is not supported"
        case .bufferCreationFailed: return "Failed to create audio buffer from WAV data"
        }
    }
}

struct AudioCaptureStartToken: Hashable, Sendable {
    fileprivate let id: UUID

    init(id: UUID = UUID()) {
        self.id = id
    }
}

/// Process-wide lease for the foreground microphone. Dictate and Notes own
/// separate AudioCaptureService instances, but iOS exposes one shared
/// AVAudioSession; allowing both engines to start would let either teardown
/// interrupt and discard the other's recording.
final class ForegroundAudioCaptureLeaseRegistry: @unchecked Sendable {
    static let shared = ForegroundAudioCaptureLeaseRegistry()

    let lock = NSLock()
    var owner: AudioCaptureStartToken?

    func acquire(_ token: AudioCaptureStartToken) -> Bool {
        lock.withLock {
            guard owner == nil else { return false }
            owner = token
            return true
        }
    }

    func release(_ token: AudioCaptureStartToken) {
        lock.withLock {
            guard owner == token else { return }
            owner = nil
        }
    }
}

/// Narrow capture seam used by DictationViewModel. Tests can control the
/// asynchronous start completion without constructing AVAudioEngine hardware.
protocol AudioCapturing: AnyObject, Sendable {
    var currentAudioLevel: Float { get }
    var isRecording: Bool { get }
    var isStarting: Bool { get }
    func micPermissionStatus() -> AVAudioSession.RecordPermission
    func requestMicPermission() async -> Bool
    @discardableResult
    func startCapture(
        onInterruption: @escaping @Sendable () -> Void,
        onMaximumDurationReached: @escaping @Sendable (Data?) -> Void,
        completion: @escaping @Sendable (Error?) -> Void
    ) -> AudioCaptureStartToken
    @MainActor
    @discardableResult
    func stopCapture() -> Data?
}

// MARK: - AudioCaptureService

/// Records audio using AVAudioEngine and produces 16kHz 16-bit mono PCM buffers.
/// Stores one bounded utterance of up to five minutes without dropping its
/// beginning. Reaching the limit atomically finalizes the WAV and notifies the
/// owner, just as if the user had pressed Stop.
///
/// Key design decisions:
/// - `captureFormat`, `isRecording`, `encodeToWAV`, `decodeWAV`, and `encodeToM4A` are intentionally
///   nonisolated so tests can call them synchronously without MainActor context.
/// - Internal state mutations happen on the main actor via DispatchQueue.main or Task.
final class AudioCaptureService: AudioCapturing, @unchecked Sendable {
    // MARK: - Public Properties

    /// The capture format: 16kHz, 16-bit integer PCM, mono.
    nonisolated let captureFormat: AVAudioFormat = {
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: 16_000,
            channels: 1,
            interleaved: false
        ) else {
            fatalError("Failed to create capture format")
        }
        return format
    }()

    /// True only after AVAudioEngine has really started.
    var isRecording: Bool {
        lifecycleLock.withLock {
            guard case .recording = activeCapture?.phase else { return false }
            return true
        }
    }

    /// True while asynchronous session/engine setup is still in flight.
    var isStarting: Bool {
        lifecycleLock.withLock {
            guard case .starting = activeCapture?.phase else { return false }
            return true
        }
    }

    /// Current audio level (0.0-1.0), written from audio thread. Read from main thread via polling.
    nonisolated(unsafe) var currentAudioLevel: Float = 0

    // MARK: - Private Properties

    let engine = AVAudioEngine()
    let lock = NSLock()
    let converterLock = NSLock()
    let lifecycleLock = NSLock()
    let captureQueue = DispatchQueue(
        label: "com.fonos.ios.audio-capture-lifecycle",
        qos: .userInitiated
    )

    enum CapturePhase: Equatable {
        case starting
        case recording
        case finalizingAtLimit
    }

    struct ActiveCapture {
        let token: AudioCaptureStartToken
        var phase: CapturePhase
        let onInterruption: @Sendable () -> Void
        let onMaximumDurationReached: @Sendable (Data?) -> Void
    }

    var activeCapture: ActiveCapture?
    /// Bridges the tiny interval between the service's automatic finalization
    /// and the MainActor receiving its callback. A simultaneous user Stop can
    /// consume the same full WAV instead of mistaking the capture for empty.
    var automaticallyFinalizedWAV: Data?
    var automaticallyFinalizedResultAvailable = false

    /// These flags are confined to `captureQueue` and make teardown
    /// idempotent across cancellation, setup failure, interruption and stop.
    var inputTapInstalled = false
    var audioSessionActive = false
    var foregroundCapturePaused = false
    var converter: AVAudioConverter?
    var converterOutputBuffer: AVAudioPCMBuffer?

    /// Fixed storage for a single bounded recording. Unlike the old ring
    /// buffer, this never overwrites the beginning of a long utterance.
    static let maxSamples = AudioCapturePolicy.maximumSamples
    var sampleBuffer: [Int16] = []
    var totalSamplesWritten = 0

    // MARK: - Init / Deinit

    init() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleInterruption(_:)),
            name: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance()
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - Public API

    /// Check current microphone permission status.
    nonisolated func micPermissionStatus() -> AVAudioSession.RecordPermission {
        // Keep the existing protocol type so capture test doubles remain simple,
        // while sourcing the permission from the iOS 17 API. Both enums use the
        // same four-character raw values for their three permission states.
        let rawValue = UInt(AVAudioApplication.shared.recordPermission.rawValue)
        guard let permission = AVAudioSession.RecordPermission(rawValue: rawValue) else {
            preconditionFailure("AVAudioApplication returned an unknown record-permission value")
        }
        return permission
    }

    /// Request microphone permission. Call only when status is .undetermined.
    func requestMicPermission() async -> Bool {
        await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission { granted in
                continuation.resume(returning: granted)
            }
        }
    }

    nonisolated(unsafe) static var tapCallCount = 0
}
