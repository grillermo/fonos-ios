import UIKit
@preconcurrency import AVFoundation
import SwiftData
import os.log

let backgroundRecordingLog = Logger(subsystem: "com.fonos.ios", category: "BackgroundRec")

final class KeyboardAudioConverterInput: @unchecked Sendable {
    private var buffer: AVAudioPCMBuffer?
    private var wasProvided = false

    func reset(buffer: AVAudioPCMBuffer) {
        self.buffer = buffer
        wasProvided = false
    }

    func clear() {
        buffer = nil
        wasProvided = false
    }

    func next(
        status: UnsafeMutablePointer<AVAudioConverterInputStatus>
    ) -> AVAudioBuffer? {
        guard !wasProvided, let buffer else {
            status.pointee = .noDataNow
            return nil
        }
        wasProvided = true
        status.pointee = .haveData
        return buffer
    }
}

struct KeyboardReadySession: Equatable, Sendable {
    let id: String
    let startedAt: Date
    let expiresAt: Date

    func isActive(at date: Date = Date()) -> Bool {
        expiresAt > date
    }
}

enum KeyboardReadySessionError: Error, LocalizedError {
    case microphonePermissionDenied
    case noAudioInput
    case engineStartFailed(Error)

    var errorDescription: String? {
        switch self {
        case .microphonePermissionDenied:
            String(localized: "Microphone permission is required for Keyboard Ready.")
        case .noAudioInput:
            String(localized: "No audio input is available.")
        case .engineStartFailed(let error):
            String(localized: "Keyboard Ready could not start: \(error.localizedDescription)")
        }
    }
}

extension Notification.Name {
    static let keyboardReadySessionDidChange = Notification.Name(
        "com.fonos.ios.keyboard-ready-session-did-change"
    )
}

struct BackgroundClipboardVoiceWorkflowOutput: VoiceWorkflowOutput {
    func deliver(text: String, context: VoiceWorkflowOutputContext) async throws {
        try await AnyTextDestination(ClipboardDestination()).send(text: text)
    }
}

struct PreparedKeyboardWorkflow: Sendable {
    let sessionID: String?
    let sourceStartedAt: Date
    let definition: WorkflowDefinition
    let plan: ResolvedVoiceWorkflow
    let delivery: KeyboardIPC.Delivery
    let destinationSummary: String
}

struct KeyboardCaptureResult {
    let pcm: Data
    let overflowed: Bool
    let conversionFailed: Bool
}

enum KeyboardUtteranceStopReason: Equatable, Sendable {
    case user
    case maximumDuration
    case readySessionExpired
}

struct KeyboardUtteranceDeadline: Equatable, Sendable {
    let date: Date
    let reason: KeyboardUtteranceStopReason

    static func resolve(
        startedAt: Date,
        readyExpiresAt: Date
    ) -> KeyboardUtteranceDeadline {
        let maximumDurationDate = startedAt.addingTimeInterval(
            AudioCapturePolicy.maximumDuration
        )
        if readyExpiresAt <= maximumDurationDate {
            return KeyboardUtteranceDeadline(
                date: readyExpiresAt,
                reason: .readySessionExpired
            )
        }
        return KeyboardUtteranceDeadline(
            date: maximumDurationDate,
            reason: .maximumDuration
        )
    }
}

/// The Keyboard Ready graph and foreground capture share AVAudioSession even
/// though they use separate AVAudioEngine instances. Ready cleanup must never
/// deactivate that shared session while Dictate or Notes owns it.
enum KeyboardReadyAudioSessionPolicy {
    static func shouldDeferExpiry(foregroundCaptureDepth: Int) -> Bool {
        foregroundCaptureDepth > 0
    }

    static func shouldDeactivateSession(foregroundCaptureDepth: Int) -> Bool {
        foregroundCaptureDepth == 0
    }
}

enum KeyboardWorkflowHistory {
    static func destinationSummary(
        outputs: [KeyboardIPC.OutputDescriptor]
    ) -> String {
        var destinations: [String] = []
        for output in outputs {
            let destination: String
            switch output.typeTag {
            case "insert", "return_to_caller": destination = "keyboard"
            case "clipboard": destination = "clipboard"
            default: destination = output.typeTag
            }
            if !destinations.contains(destination) {
                destinations.append(destination)
            }
        }
        return destinations.joined(separator: ",")
    }
}

enum KeyboardReadyAudioLoss {
    case interruption
    case routeChange
    case mediaServicesReset
    case engineConfigurationChange

    var userMessage: String {
        switch self {
        case .interruption:
            String(localized: "Recording stopped because audio was interrupted. Wait for Keyboard Ready, then try again.")
        case .routeChange:
            String(localized: "Recording stopped because the microphone route changed. Wait for Keyboard Ready, then try again.")
        case .mediaServicesReset:
            String(localized: "Recording stopped because iOS reset audio services. Wait for Keyboard Ready, then try again.")
        case .engineConfigurationChange:
            String(localized: "Recording stopped because the microphone configuration changed. Wait for Keyboard Ready, then try again.")
        }
    }
}

enum KeyboardReadyCaptureSetupError: Error, LocalizedError {
    case converterUnavailable
    case outputBufferUnavailable

    var errorDescription: String? {
        switch self {
        case .converterUnavailable:
            String(localized: "The current microphone format cannot be converted for dictation.")
        case .outputBufferUnavailable:
            String(localized: "Fonos could not allocate its keyboard audio buffer.")
        }
    }
}

/// Audio bridge for the keyboard extension.
///
/// A custom keyboard cannot access the microphone. The user therefore starts
/// an explicit, time-limited Keyboard Ready session in the containing app while
/// it is foregrounded. An AVAudioEngine input graph then stays alive when the
/// app backgrounds. Idle tap buffers are discarded immediately; PCM is kept in
/// bounded memory only between the keyboard's start and stop commands.
final class BackgroundRecordingService: NSObject, @unchecked Sendable {
    static let shared = BackgroundRecordingService()

    let groupID = KeyboardIPC.appGroupID

    var engine = AVAudioEngine()
    let registrationLock = NSLock()
    let captureLock = NSLock()
    let captureFormat: AVAudioFormat = {
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: 16_000,
            channels: 1,
            interleaved: false
        ) else {
            fatalError("Failed to create keyboard capture format")
        }
        return format
    }()
    static let maxUtteranceSamples = AudioCapturePolicy.maximumSamples
    static let tapBufferSize: AVAudioFrameCount = 4096
    var capturedSamples: [Int16] = []
    var acceptsCaptureBuffers = false
    var captureOverflowed = false
    var captureConversionFailed = false
    var captureLimitNotificationScheduled = false
    var tapCaptureID: UUID?
    var readyAudioConverter: AVAudioConverter?
    let readyConverterInput = KeyboardAudioConverterInput()
    lazy var readyConverterInputBlock: AVAudioConverterInputBlock = { [weak self] _, status in
        guard let self else {
            status.pointee = .noDataNow
            return nil
        }
        return self.readyConverterInput.next(status: status)
    }
    var readyConvertedBuffer: AVAudioPCMBuffer?
    var readyConverterInputFormat: AVAudioFormat?
    var inputTapInstalled = false
    var recordingStartDate = Date()
    var isKeyboardRecording = false
    var activeKeyboardCaptureID: UUID?
    var utteranceDeadlineWorkItem: DispatchWorkItem?
    var readySession: KeyboardReadySession?
    var readinessStatus: KeyboardIPC.ReadinessStatus = .inactive
    var heartbeatTimer: Timer?
    /// Definition, providers, vocab and delivery route are all frozen on the
    /// keyboard's start event, never re-read after audio capture.
    var preparedKeyboardWorkflow: PreparedKeyboardWorkflow?
    var processingTask: Task<Void, Never>?
    var processingRunID: UUID?
    var processingSessionID: String?
    var processingBackgroundTaskID: UIBackgroundTaskIdentifier = .invalid
    var sessionState = KeyboardIPCProducerSessionState()
    let appInstanceID = UUID().uuidString
    var foregroundCaptureDepth = 0
    var isRegistered = false
    var isManagingReadyEngine = false
    var readyEngineRecoveryGeneration = 0
    var suppressGraphChangesUntil = Date.distantPast
    @MainActor var modelContext: ModelContext?

    static nonisolated(unsafe) let kbStart = KeyboardIPC.NotificationName.start as CFString
    static nonisolated(unsafe) let kbStop = KeyboardIPC.NotificationName.stop as CFString
    static nonisolated(unsafe) let kbCancel = KeyboardIPC.NotificationName.cancel as CFString

    private override init() { super.init() }

    @MainActor
    func configure(modelContext: ModelContext) {
        self.modelContext = modelContext
    }

    // MARK: - Registration (called on app launch, while in FOREGROUND)

}
