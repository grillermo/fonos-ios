import UIKit
@preconcurrency import AVFoundation
import SwiftData
import os.log

private let bgLog = Logger(subsystem: "com.fonos.ios", category: "BackgroundRec")

private final class KeyboardAudioConverterInput: @unchecked Sendable {
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

private struct BackgroundClipboardVoiceWorkflowOutput: VoiceWorkflowOutput {
    func deliver(text: String, context: VoiceWorkflowOutputContext) async throws {
        try await AnyTextDestination(ClipboardDestination()).send(text: text)
    }
}

private struct PreparedKeyboardWorkflow: Sendable {
    let sessionID: String?
    let sourceStartedAt: Date
    let definition: WorkflowDefinition
    let plan: ResolvedVoiceWorkflow
    let delivery: KeyboardIPC.Delivery
    let destinationSummary: String
}

private struct KeyboardCaptureResult {
    let pcm: Data
    let overflowed: Bool
    let conversionFailed: Bool
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

private enum KeyboardReadyAudioLoss {
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

private enum KeyboardReadyCaptureSetupError: Error, LocalizedError {
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

    private let groupID = KeyboardIPC.appGroupID

    private var engine = AVAudioEngine()
    private let registrationLock = NSLock()
    private let captureLock = NSLock()
    private let captureFormat: AVAudioFormat = {
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
    private static let maxUtteranceSamples = 16_000 * 5 * 60
    private static let tapBufferSize: AVAudioFrameCount = 4096
    private var capturedSamples: [Int16] = []
    private var acceptsCaptureBuffers = false
    private var captureOverflowed = false
    private var captureConversionFailed = false
    private var readyAudioConverter: AVAudioConverter?
    private let readyConverterInput = KeyboardAudioConverterInput()
    private lazy var readyConverterInputBlock: AVAudioConverterInputBlock = { [weak self] _, status in
        guard let self else {
            status.pointee = .noDataNow
            return nil
        }
        return self.readyConverterInput.next(status: status)
    }
    private var readyConvertedBuffer: AVAudioPCMBuffer?
    private var readyConverterInputFormat: AVAudioFormat?
    private var inputTapInstalled = false
    private var recordingStartDate = Date()
    private var isKeyboardRecording = false
    private var readySession: KeyboardReadySession?
    private var readinessStatus: KeyboardIPC.ReadinessStatus = .inactive
    private var heartbeatTimer: Timer?
    /// Definition, providers, vocab and delivery route are all frozen on the
    /// keyboard's start event, never re-read after audio capture.
    private var preparedKeyboardWorkflow: PreparedKeyboardWorkflow?
    private var processingTask: Task<Void, Never>?
    private var processingRunID: UUID?
    private var processingSessionID: String?
    private var processingBackgroundTaskID: UIBackgroundTaskIdentifier = .invalid
    private var sessionState = KeyboardIPCProducerSessionState()
    private let appInstanceID = UUID().uuidString
    private var foregroundCaptureDepth = 0
    private var isRegistered = false
    private var isManagingReadyEngine = false
    private var readyEngineRecoveryGeneration = 0
    private var suppressGraphChangesUntil = Date.distantPast
    @MainActor private var modelContext: ModelContext?

    private static nonisolated(unsafe) let kbStart = KeyboardIPC.NotificationName.start as CFString
    private static nonisolated(unsafe) let kbStop = KeyboardIPC.NotificationName.stop as CFString
    private static nonisolated(unsafe) let kbCancel = KeyboardIPC.NotificationName.cancel as CFString

    private override init() { super.init() }

    @MainActor
    func configure(modelContext: ModelContext) {
        self.modelContext = modelContext
    }

    // MARK: - Registration (called on app launch, while in FOREGROUND)

    func register() {
        guard Thread.isMainThread else {
            DispatchQueue.main.sync { [self] in register() }
            return
        }

        registrationLock.lock()
        guard !isRegistered else {
            registrationLock.unlock()
            bgLog.debug("BackgroundRecordingService already registered")
            return
        }
        isRegistered = true
        registrationLock.unlock()

        registerDarwinObservers()

        // Verify App Group
        if let url = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupID) {
            bgLog.info("✅ App Group: \(url.path)")
        } else {
            bgLog.error("❌ App Group NOT accessible!")
        }

        resetKeyboardIPCForNewAppInstance()
        deleteFile(KeyboardIPC.FileName.continuousAudio)
        deleteFile(KeyboardIPC.FileName.segmentAudio)
        publishReadiness(.inactive)

        // The heartbeat is deliberately withheld until the user explicitly
        // enables Keyboard Ready and the input graph is actually running.
        updateHeartbeat()
        heartbeatTimer?.invalidate()
        heartbeatTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.updateHeartbeat()
        }

        registerSystemObservers()

        bgLog.info("✅ BackgroundRecordingService registered")
    }

    private func registerDarwinObservers() {
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        let observer = Unmanaged.passUnretained(self).toOpaque()

        CFNotificationCenterAddObserver(center, observer, { _, obs, _, _, _ in
            guard let obs else { return }
            Unmanaged<BackgroundRecordingService>.fromOpaque(obs).takeUnretainedValue().onStart()
        }, Self.kbStart, nil, .deliverImmediately)

        CFNotificationCenterAddObserver(center, observer, { _, obs, _, _, _ in
            guard let obs else { return }
            Unmanaged<BackgroundRecordingService>.fromOpaque(obs).takeUnretainedValue().onStop()
        }, Self.kbStop, nil, .deliverImmediately)

        CFNotificationCenterAddObserver(center, observer, { _, obs, _, _, _ in
            guard let obs else { return }
            Unmanaged<BackgroundRecordingService>.fromOpaque(obs).takeUnretainedValue().onCancel()
        }, Self.kbCancel, nil, .deliverImmediately)
    }

    private func registerSystemObservers() {
        registerForegroundObserver()
        registerAudioInterruptionObserver()
        registerRouteChangeObserver()
        registerMediaServicesResetObserver()
        registerEngineConfigurationObserver()
    }

    private func registerForegroundObserver() {
        // A valid ready session may recover its input graph when the containing
        // app returns to foreground after an interruption or route change.
        NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            self.scheduleReadyEngineRecovery(after: 0)
        }
    }

    private func registerAudioInterruptionObserver() {
        NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self,
                  let info = notification.userInfo,
                  let typeValue = info[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: typeValue) else { return }

            if type == .began {
                bgLog.info("🎙 Keyboard Ready audio interrupted")
                self.handleReadyAudioLoss(.interruption, recoverAutomatically: false)
            } else if type == .ended {
                bgLog.info("🎙 Keyboard Ready interruption ended")
                self.scheduleReadyEngineRecovery(after: 0.15)
            }
        }
    }

    private func registerRouteChangeObserver() {
        NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self,
                  let rawReason = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
                  let reason = AVAudioSession.RouteChangeReason(rawValue: rawReason),
                  Self.routeChangeRequiresReadyEngineRebuild(reason) else { return }
            if Date() < self.suppressGraphChangesUntil, self.engine.isRunning { return }
            bgLog.info("🎙 Keyboard Ready route changed: \(rawReason)")
            self.handleReadyAudioLoss(.routeChange, recoverAutomatically: true)
        }
    }

    private func registerMediaServicesResetObserver() {
        NotificationCenter.default.addObserver(
            forName: AVAudioSession.mediaServicesWereResetNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            bgLog.warning("🎙 Keyboard Ready audio services reset")
            self.handleReadyAudioLoss(
                .mediaServicesReset,
                recoverAutomatically: true,
                recreateEngine: true
            )
        }
    }

    private func registerEngineConfigurationObserver() {
        NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self,
                  let changedEngine = notification.object as? AVAudioEngine,
                  changedEngine === self.engine,
                  !self.isManagingReadyEngine else { return }
            if Date() < self.suppressGraphChangesUntil { return }
            bgLog.warning("🎙 Keyboard Ready engine configuration changed")
            self.handleReadyAudioLoss(
                .engineConfigurationChange,
                recoverAutomatically: true
            )
        }
    }

    static func routeChangeRequiresReadyEngineRebuild(
        _ reason: AVAudioSession.RouteChangeReason
    ) -> Bool {
        switch reason {
        case .newDeviceAvailable, .oldDeviceUnavailable,
             .wakeFromSleep, .noSuitableRouteForCategory,
             .routeConfigurationChange:
            true
        case .unknown, .categoryChange, .override:
            false
        @unknown default:
            true
        }
    }

    // MARK: - Explicit Keyboard Ready session

    @MainActor
    var keyboardReadySession: KeyboardReadySession? {
        readySession
    }

    @MainActor
    var isKeyboardReady: Bool {
        readySession?.isActive() == true
            && foregroundCaptureDepth == 0
            && engine.isRunning
    }

    @MainActor
    var keyboardReadinessStatus: KeyboardIPC.ReadinessStatus {
        readinessStatus
    }

    /// Starts or renews the bounded Keyboard Ready window. This must be called
    /// from an explicit user action while the containing app is foregrounded.
    @MainActor
    func enableKeyboardReadySession(
        duration: TimeInterval = KeyboardIPC.defaultReadySessionDuration
    ) async throws -> KeyboardReadySession {
        let granted: Bool
        switch AVAudioApplication.shared.recordPermission {
        case .granted:
            granted = true
        case .denied:
            granted = false
        case .undetermined:
            granted = await withCheckedContinuation { continuation in
                AVAudioApplication.requestRecordPermission { allowed in
                    continuation.resume(returning: allowed)
                }
            }
        @unknown default:
            granted = false
        }
        guard granted else {
            throw KeyboardReadySessionError.microphonePermissionDenied
        }

        do {
            try startReadyEngine()
        } catch let error as KeyboardReadySessionError {
            throw error
        } catch {
            throw KeyboardReadySessionError.engineStartFailed(error)
        }

        let now = Date()
        let clampedDuration = KeyboardIPC.clampedReadySessionDuration(duration)
        let session = KeyboardReadySession(
            id: readySession?.id ?? UUID().uuidString,
            startedAt: readySession?.startedAt ?? now,
            expiresAt: now.addingTimeInterval(clampedDuration)
        )
        readySession = session
        publishReadiness(.ready)
        updateHeartbeat()
        bgLog.info("🎙 Keyboard Ready enabled until \(session.expiresAt, privacy: .public)")
        return session
    }

    @MainActor
    func disableKeyboardReadySession() {
        disableKeyboardReadySession(reason: .inactive, notifyActiveKeyboard: true)
    }

    private func startReadyEngine() throws {
        if engine.isRunning,
           inputTapInstalled,
           readyAudioConverter != nil,
           readyConvertedBuffer != nil {
            return
        }

        isManagingReadyEngine = true
        var didStart = false
        defer {
            if !didStart {
                stopReadyEngine(removeTap: true, deactivateSession: true)
            }
            isManagingReadyEngine = false
        }

        if engine.isRunning {
            stopReadyEngine(removeTap: true, deactivateSession: true)
        }

        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(
                .playAndRecord,
                mode: .default,
                options: [.mixWithOthers, .allowBluetoothHFP]
            )
            try session.setPreferredSampleRate(16_000)
            try session.setActive(true, options: .notifyOthersOnDeactivation)
        } catch {
            throw KeyboardReadySessionError.engineStartFailed(error)
        }

        let inputNode = engine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)
        guard inputFormat.channelCount > 0, inputFormat.sampleRate > 0 else {
            throw KeyboardReadySessionError.noAudioInput
        }

        let formatChanged = readyConverterInputFormat.map {
            !$0.isEqual(inputFormat)
        } ?? true
        if inputTapInstalled && formatChanged {
            inputNode.removeTap(onBus: 0)
            inputTapInstalled = false
            clearReadyCapturePipeline(releaseStorage: false)
        }

        if !inputTapInstalled {
            try prepareReadyCapturePipeline(inputFormat: inputFormat)
            inputNode.installTap(
                onBus: 0,
                bufferSize: Self.tapBufferSize,
                format: nil
            ) { [weak self] buffer, _ in
                self?.processReadyTapBuffer(buffer)
            }
            inputTapInstalled = true
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            throw KeyboardReadySessionError.engineStartFailed(error)
        }
        didStart = true
        suppressGraphChangesUntil = Date().addingTimeInterval(0.75)
        bgLog.info("🎙 Keyboard Ready input graph running; idle buffers are discarded")
    }

    private func stopReadyEngine(removeTap: Bool, deactivateSession: Bool) {
        let wasManaging = isManagingReadyEngine
        isManagingReadyEngine = true
        defer { isManagingReadyEngine = wasManaging }

        stopCapturingUtterance()
        engine.stop()
        if removeTap, inputTapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            inputTapInstalled = false
        }
        if removeTap {
            clearReadyCapturePipeline(releaseStorage: true)
        }
        if deactivateSession {
            try? AVAudioSession.sharedInstance().setActive(
                false,
                options: .notifyOthersOnDeactivation
            )
        }
    }

    private func prepareReadyCapturePipeline(inputFormat: AVAudioFormat) throws {
        guard let converter = AVAudioConverter(from: inputFormat, to: captureFormat) else {
            throw KeyboardReadySessionError.engineStartFailed(
                KeyboardReadyCaptureSetupError.converterUnavailable
            )
        }
        let ratio = captureFormat.sampleRate / inputFormat.sampleRate
        let convertedCapacity = max(
            Self.tapBufferSize,
            AVAudioFrameCount(ceil(Double(Self.tapBufferSize) * ratio)) + 1_024
        )
        guard let convertedBuffer = AVAudioPCMBuffer(
            pcmFormat: captureFormat,
            frameCapacity: convertedCapacity
        ) else {
            throw KeyboardReadySessionError.engineStartFailed(
                KeyboardReadyCaptureSetupError.outputBufferUnavailable
            )
        }

        readyAudioConverter = converter
        readyConvertedBuffer = convertedBuffer
        readyConverterInputFormat = inputFormat
        _ = readyConverterInputBlock // Materialize the closure off the tap thread.
        captureLock.lock()
        capturedSamples.reserveCapacity(Self.maxUtteranceSamples)
        captureLock.unlock()
    }

    private func clearReadyCapturePipeline(releaseStorage: Bool) {
        captureLock.lock()
        readyConverterInput.clear()
        readyAudioConverter = nil
        readyConvertedBuffer = nil
        readyConverterInputFormat = nil
        acceptsCaptureBuffers = false
        captureOverflowed = false
        captureConversionFailed = false
        if releaseStorage {
            capturedSamples = []
        } else {
            capturedSamples.removeAll(keepingCapacity: true)
        }
        captureLock.unlock()
    }

    private func handleReadyAudioLoss(
        _ loss: KeyboardReadyAudioLoss,
        recoverAutomatically: Bool,
        recreateEngine: Bool = false
    ) {
        guard readySession != nil, foregroundCaptureDepth == 0 else { return }
        let utteranceWasActive = isKeyboardRecording
        expireReadySessionIfNeeded()
        guard readySession?.isActive() == true || utteranceWasActive else { return }

        if isKeyboardRecording {
            let sessionID = sessionState.captureForResult()
            isKeyboardRecording = false
            preparedKeyboardWorkflow = nil
            stopCapturingUtterance()
            _ = writeError(loss.userMessage, sessionID: sessionID)
            finishExpiredReadySessionIfPossible()
        } else {
            stopCapturingUtterance()
        }
        guard readySession != nil else { return }
        publishReadiness(.paused)
        writeFile(KeyboardIPC.FileName.heartbeat, "0")

        if recoverAutomatically {
            scheduleReadyEngineRecovery(
                after: 0.2,
                recreateEngine: recreateEngine
            )
        } else {
            scheduleReadyEngineTeardown(recreateEngine: recreateEngine)
        }
    }

    private func scheduleReadyEngineTeardown(recreateEngine: Bool) {
        readyEngineRecoveryGeneration += 1
        let generation = readyEngineRecoveryGeneration
        DispatchQueue.main.async { [weak self] in
            guard let self, generation == self.readyEngineRecoveryGeneration else { return }
            self.stopReadyEngine(removeTap: true, deactivateSession: true)
            if recreateEngine {
                self.engine = AVAudioEngine()
            }
        }
    }

    private func scheduleReadyEngineRecovery(
        after delay: TimeInterval,
        recreateEngine: Bool = false
    ) {
        readyEngineRecoveryGeneration += 1
        let generation = readyEngineRecoveryGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, generation == self.readyEngineRecoveryGeneration else { return }
            self.expireReadySessionIfNeeded()
            guard self.readySession?.isActive() == true,
                  self.foregroundCaptureDepth == 0 else { return }

            self.stopReadyEngine(removeTap: true, deactivateSession: true)
            if recreateEngine {
                self.engine = AVAudioEngine()
            }
            do {
                try self.startReadyEngine()
                self.publishReadiness(.ready)
                self.updateHeartbeat()
                bgLog.info("🎙 Keyboard Ready audio graph recovered")
            } catch {
                self.publishReadiness(.paused)
                self.writeFile(KeyboardIPC.FileName.heartbeat, "0")
                bgLog.error("🎙 Keyboard Ready recovery failed: \(error.localizedDescription)")
            }
        }
    }

    /// Pause Keyboard Ready while the foreground Dictate surface owns audio.
    func pauseForForegroundCapture() {
        runOnMainSync { [self] in
            foregroundCaptureDepth += 1
            guard foregroundCaptureDepth == 1 else { return }

            isKeyboardRecording = false
            cancelProcessingTask()
            preparedKeyboardWorkflow = nil
            sessionState = KeyboardIPCProducerSessionState()
            stopReadyEngine(removeTap: false, deactivateSession: false)
            writeFile(KeyboardIPC.FileName.heartbeat, "0")
            clearKeyboardIPCResultFiles()
            if readySession != nil { publishReadiness(.paused) }
            bgLog.info("🎙 Keyboard Ready paused for foreground capture")
        }
    }

    /// Resume keyboard readiness after foreground app dictation releases the
    /// audio session. Must be called while the app is foreground-capable.
    func resumeAfterForegroundCapture() {
        runOnMainSync { [self] in
            guard foregroundCaptureDepth > 0 else { return }
            foregroundCaptureDepth -= 1
            guard foregroundCaptureDepth == 0 else { return }

            expireReadySessionIfNeeded()
            guard readySession?.isActive() == true else { return }
            do {
                try startReadyEngine()
                resetKeyboardIPCForRecorderRestart()
                publishReadiness(.ready)
                updateHeartbeat()
                bgLog.info("🎙 Keyboard Ready resumed after foreground capture")
            } catch {
                publishReadiness(.paused)
                bgLog.error("🎙 Keyboard Ready resume failed: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Keyboard utterance

    private func onStart() {
        DispatchQueue.main.async { [self] in
            // A new keyboard session supersedes any stale processing result.
            // Engine cancellation checks prevent its remaining outputs from
            // running; session guards prevent late file publication.
            cancelProcessingTask()
            let requestedSessionID = readFile(KeyboardIPC.FileName.sessionID)
            preparedKeyboardWorkflow = nil
            expireReadySessionIfNeeded()
            sessionState.begin(sessionID: requestedSessionID)
            guard readySession?.isActive() == true,
                  foregroundCaptureDepth == 0,
                  engine.isRunning else {
                bgLog.error("🎙 Keyboard start rejected: Keyboard Ready is inactive")
                writeError("Open Fonos and enable Keyboard Ready, then try again.",
                           sessionID: sessionState.captureForResult())
                return
            }

            if isKeyboardRecording {
                bgLog.warning("🎙 Previous keyboard utterance was still active; replacing it")
            }
            var config = readAppConfig()
            WorkflowMigration.migrate(&config)
            let workflowID = resolveWorkflowID(config: config)
            let catalog = config.workflowCatalog
            guard let definition = catalog.workflow(id: workflowID) else {
                writeError(
                    "Voice recipe is unavailable",
                    sessionID: sessionState.captureForResult()
                )
                return
            }
            let outputDescriptors: [KeyboardIPC.OutputDescriptor] = definition.outputs.compactMap { outputID in
                guard let widget = catalog.widget(id: outputID) else { return nil }
                return KeyboardIPC.OutputDescriptor(
                    typeTag: widget.typeTag,
                    pressEnter: widget.props["press_enter"]?.boolValue == true
                )
            }
            let delivery = KeyboardIPC.resolvedDelivery(outputs: outputDescriptors)
            let plan: ResolvedVoiceWorkflow
            do {
                plan = try compileKeyboardWorkflow(
                    definition: definition,
                    catalog: catalog,
                    config: config
                )
            } catch {
                bgLog.error("🎙 BG: recipe preflight failed: \(error.localizedDescription)")
                writeError(
                    "Recipe: \(error.localizedDescription)",
                    sessionID: sessionState.captureForResult()
                )
                return
            }

            recordingStartDate = Date()
            preparedKeyboardWorkflow = PreparedKeyboardWorkflow(
                sessionID: sessionState.captureForResult(),
                sourceStartedAt: recordingStartDate,
                definition: definition,
                plan: plan,
                delivery: delivery,
                destinationSummary: KeyboardWorkflowHistory.destinationSummary(
                    outputs: outputDescriptors
                )
            )
            startCapturingUtterance()
            isKeyboardRecording = true
            if let sessionID = sessionState.activeSessionID {
                writeFile(KeyboardIPC.FileName.startAckSessionID, sessionID)
            }
            writeStatus("recording")
            bgLog.info("🎙 Keyboard utterance started; session=\((self.sessionState.activeSessionID ?? "-").prefix(8))")
        }
    }

    private func onCancel() {
        DispatchQueue.main.async { [self] in
            let requestedSessionID = readFile(KeyboardIPC.FileName.cancelSessionID)
            deleteFile(KeyboardIPC.FileName.cancelSessionID)
            guard sessionState.cancelIfActive(sessionID: requestedSessionID) else {
                if let requestedSessionID, !requestedSessionID.isEmpty {
                    bgLog.info("🎙 BG: ignored stale cancel for session \(requestedSessionID.prefix(8))")
                }
                return
            }

            isKeyboardRecording = false
            stopCapturingUtterance()
            preparedKeyboardWorkflow = nil
            cancelProcessingTask()
            writeStatus("cancelled")
            finishExpiredReadySessionIfPossible()
            bgLog.info("🎙 BG: cancelled keyboard session \((requestedSessionID ?? "-").prefix(8))")
        }
    }

    private func onStop() {
        DispatchQueue.main.async { [self] in
            guard isKeyboardRecording else {
                bgLog.warning("Not keyboard-recording, ignoring stop")
                preparedKeyboardWorkflow = nil
                return
            }

            let sessionID = sessionState.captureForResult()
            let capture = finishCapturingUtterance()
            isKeyboardRecording = false
            guard let prepared = preparedKeyboardWorkflow,
                  prepared.sessionID == sessionID else {
                writeError("Voice recipe snapshot expired. Try again.", sessionID: sessionID)
                finishExpiredReadySessionIfPossible()
                return
            }
            preparedKeyboardWorkflow = nil
            let stopWallClock = Date()
            let wallDuration = max(0, stopWallClock.timeIntervalSince(recordingStartDate))
            bgLog.info("🎙 BG: Stop requested. Wall duration=\(String(format: "%.2f", wallDuration))s")

            if capture.conversionFailed {
                writeError(
                    String(localized: "Audio input changed while recording. Wait for Keyboard Ready, then try again."),
                    sessionID: sessionID
                )
                finishExpiredReadySessionIfPossible()
                return
            }
            if capture.overflowed {
                writeError("Keyboard dictation is limited to five minutes.", sessionID: sessionID)
                finishExpiredReadySessionIfPossible()
                return
            }
            let wavData = WAVSegment.build(
                from: capture.pcm[capture.pcm.startIndex..<capture.pcm.endIndex],
                sampleRate: 16_000
            )
            let capturedDuration = WAVSegment.duration(of: wavData, sampleRate: 16_000)
            guard capturedDuration >= 0.4, wavData.count > 100 else {
                writeError("No audio captured. Try again.", sessionID: sessionID)
                finishExpiredReadySessionIfPossible()
                return
            }

            // Background task for transcription
            var bgTaskID: UIBackgroundTaskIdentifier = .invalid
            bgTaskID = UIApplication.shared.beginBackgroundTask { [weak self] in
                DispatchQueue.main.async {
                    guard let self else { return }
                    bgLog.warning("🎙 BG: Background task expiring")
                    self.expireProcessing(sessionID: sessionID, backgroundTaskID: bgTaskID)
                }
            }
            processingBackgroundTaskID = bgTaskID
            processingSessionID = sessionID

            writeStatus("processing")
            expireReadySessionIfNeeded()
            finishStop(
                wavData: wavData,
                sessionID: sessionID,
                wallDuration: wallDuration,
                bgTaskID: bgTaskID,
                prepared: prepared
            )
        }
    }

    private func finishStop(
        wavData: Data,
        sessionID: String?,
        wallDuration: TimeInterval,
        bgTaskID: UIBackgroundTaskIdentifier,
        prepared: PreparedKeyboardWorkflow
    ) {
        guard sessionState.activeSessionID == sessionID,
              processingSessionID == sessionID,
              processingBackgroundTaskID == bgTaskID else {
            bgLog.info("🎙 BG: abandoned cancelled/stale stop for session \((sessionID ?? "-").prefix(8))")
            endBackgroundTask(bgTaskID)
            return
        }
        let capturedDuration = WAVSegment.duration(of: wavData, sampleRate: 16_000)
        bgLog.info(
            """
            🎙 In-memory utterance: \(wavData.count) bytes, \
            captured=\(String(format: "%.2f", capturedDuration))s, \
            wall=\(String(format: "%.2f", wallDuration))s, session=\((sessionID ?? "-").prefix(8))
            """
        )

        transcribeAndProcess(
            wavData: wavData,
            sessionID: sessionID,
            bgTaskID: bgTaskID,
            prepared: prepared
        )
    }

    private func updateHeartbeat() {
        expireReadySessionIfNeeded()
        let now = Date()
        guard foregroundCaptureDepth == 0 else {
            writeFile(KeyboardIPC.FileName.heartbeat, "0")
            return
        }

        let acceptedOperationIsActive = isKeyboardRecording || processingSessionID != nil
        if acceptedOperationIsActive
            || (readySession?.isActive(at: now) == true && engine.isRunning) {
            writeFile(KeyboardIPC.FileName.appInstanceID, appInstanceID)
            writeFile(KeyboardIPC.FileName.heartbeat, "\(now.timeIntervalSince1970)")
        } else {
            writeFile(KeyboardIPC.FileName.heartbeat, "0")
        }
    }

    private func startCapturingUtterance() {
        captureLock.lock()
        acceptsCaptureBuffers = false
        capturedSamples.removeAll(keepingCapacity: true)
        capturedSamples.reserveCapacity(Self.maxUtteranceSamples)
        captureOverflowed = false
        captureConversionFailed = false
        readyAudioConverter?.reset()
        readyConverterInput.clear()
        acceptsCaptureBuffers = true
        captureLock.unlock()
    }

    private func stopCapturingUtterance() {
        captureLock.lock()
        acceptsCaptureBuffers = false
        capturedSamples.removeAll(keepingCapacity: true)
        captureOverflowed = false
        captureConversionFailed = false
        readyConverterInput.clear()
        captureLock.unlock()
    }

    private func finishCapturingUtterance() -> KeyboardCaptureResult {
        captureLock.lock()
        acceptsCaptureBuffers = false
        let pcm = capturedSamples.withUnsafeBytes { Data($0) }
        let overflowed = captureOverflowed
        let conversionFailed = captureConversionFailed
        capturedSamples.removeAll(keepingCapacity: true)
        captureOverflowed = false
        captureConversionFailed = false
        readyConverterInput.clear()
        captureLock.unlock()

        return KeyboardCaptureResult(
            pcm: pcm,
            overflowed: overflowed,
            conversionFailed: conversionFailed
        )
    }

    /// The tap runs for the bounded Ready window so iOS keeps the containing
    /// app's audio input alive in the background. Before a keyboard start, the
    /// fast guard returns and the buffer is neither converted nor retained.
    private func processReadyTapBuffer(_ buffer: AVAudioPCMBuffer) {
        captureLock.lock()
        defer { captureLock.unlock() }
        guard acceptsCaptureBuffers else { return }
        guard readyConverterInputFormat?.isEqual(buffer.format) == true,
              let converter = readyAudioConverter,
              let converted = readyConvertedBuffer else {
            captureConversionFailed = true
            acceptsCaptureBuffers = false
            return
        }

        converted.frameLength = 0
        readyConverterInput.reset(buffer: buffer)
        var conversionError: NSError?
        let status = converter.convert(
            to: converted,
            error: &conversionError,
            withInputFrom: readyConverterInputBlock
        )
        readyConverterInput.clear()
        guard status != .error,
              conversionError == nil,
              let samples = converted.int16ChannelData?[0] else {
            captureConversionFailed = true
            acceptsCaptureBuffers = false
            return
        }

        let available = Self.maxUtteranceSamples - capturedSamples.count
        let frameCount = Int(converted.frameLength)
        guard available > 0 else {
            captureOverflowed = true
            acceptsCaptureBuffers = false
            return
        }
        let accepted = min(available, frameCount)
        capturedSamples.append(contentsOf: UnsafeBufferPointer(
            start: samples,
            count: accepted
        ))
        if accepted < frameCount {
            captureOverflowed = true
            acceptsCaptureBuffers = false
        }
    }

    private func expireReadySessionIfNeeded(at now: Date = Date()) {
        guard let readySession, !readySession.isActive(at: now) else { return }
        let operationIsActive = isKeyboardRecording || processingSessionID != nil
        if operationIsActive {
            publishReadiness(.finishing)
            // Once capture stops, processing no longer needs the live input.
            if !isKeyboardRecording, engine.isRunning {
                stopReadyEngine(removeTap: true, deactivateSession: true)
            }
            return
        }
        disableKeyboardReadySession(reason: .expired, notifyActiveKeyboard: false)
    }

    private func finishExpiredReadySessionIfPossible() {
        guard readySession?.isActive() == false,
              !isKeyboardRecording,
              processingSessionID == nil else { return }
        disableKeyboardReadySession(reason: .expired, notifyActiveKeyboard: false)
    }

    private func disableKeyboardReadySession(
        reason: KeyboardIPC.ReadinessStatus,
        notifyActiveKeyboard: Bool
    ) {
        if notifyActiveKeyboard, let sessionID = sessionState.activeSessionID {
            _ = writeError("Keyboard Ready ended in Fonos.", sessionID: sessionID)
        }
        isKeyboardRecording = false
        preparedKeyboardWorkflow = nil
        stopCapturingUtterance()
        cancelProcessingTask()
        sessionState = KeyboardIPCProducerSessionState()
        stopReadyEngine(removeTap: true, deactivateSession: true)
        readySession = nil
        deleteFile(KeyboardIPC.FileName.continuousAudio)
        deleteFile(KeyboardIPC.FileName.segmentAudio)
        writeFile(KeyboardIPC.FileName.heartbeat, "0")
        publishReadiness(reason)
    }

    private func publishReadiness(_ status: KeyboardIPC.ReadinessStatus) {
        readinessStatus = status
        writeFile(KeyboardIPC.FileName.readinessStatus, status.rawValue)
        if let readySession {
            writeFile(KeyboardIPC.FileName.readySessionID, readySession.id)
            writeFile(
                KeyboardIPC.FileName.readyExpiresAt,
                "\(readySession.expiresAt.timeIntervalSince1970)"
            )
        } else {
            deleteFile(KeyboardIPC.FileName.readySessionID)
            deleteFile(KeyboardIPC.FileName.readyExpiresAt)
        }
        NotificationCenter.default.post(
            name: .keyboardReadySessionDidChange,
            object: self
        )
    }

    // MARK: - Transcribe & Process

    private func transcribeAndProcess(
        wavData: Data,
        sessionID: String?,
        bgTaskID: UIBackgroundTaskIdentifier,
        prepared: PreparedKeyboardWorkflow
    ) {
        guard sessionState.activeSessionID == sessionID,
              processingSessionID == sessionID,
              processingBackgroundTaskID == bgTaskID else {
            endBackgroundTask(bgTaskID)
            return
        }
        bgLog.info("🎙 BG: recipe=\(prepared.definition.id, privacy: .public), components=\(prepared.plan.validation.steps.count)")

        let processingRunID = UUID()
        self.processingRunID = processingRunID
        processingTask = Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await VoiceWorkflowEngine().run(
                    VoiceWorkflowRunInput(
                        audioData: wavData,
                        source: prepared.plan.validation.sourceKind,
                        sourceAcquisitionDuration: Date().timeIntervalSince(
                            prepared.sourceStartedAt
                        )
                    ),
                    using: prepared.plan,
                    recorder: { [weak self] processed in
                        await self?.persistKeyboardSession(
                            processed: processed,
                            definition: prepared.definition,
                            destinationSummary: prepared.destinationSummary
                        )
                    }
                )
                try Task.checkCancellation()
                await MainActor.run {
                    guard self.processingRunID == processingRunID else { return }
                    // Publish only after every recipe output succeeds. Session
                    // identity makes stale completions a no-op.
                    if self.writeFinal(
                        result.finalText,
                        sessionID: sessionID,
                        delivery: prepared.delivery
                    ) {
                        bgLog.info("🎙 BG: ✅ Done: \"\(result.finalText.prefix(50))...\", session=\((sessionID ?? "-").prefix(8))")
                    }
                    self.finishProcessingTask(
                        runID: processingRunID,
                        backgroundTaskID: bgTaskID
                    )
                }
            } catch is CancellationError {
                await MainActor.run {
                    self.finishProcessingTask(
                        runID: processingRunID,
                        backgroundTaskID: bgTaskID
                    )
                }
            } catch {
                bgLog.error("🎙 BG: ❌ recipe failed: \(error.localizedDescription)")
                await MainActor.run {
                    _ = self.writeError(
                        "Recipe: \(error.localizedDescription)",
                        sessionID: sessionID
                    )
                    self.finishProcessingTask(
                        runID: processingRunID,
                        backgroundTaskID: bgTaskID
                    )
                }
            }
        }
    }

    private func finishProcessingTask(
        runID: UUID,
        backgroundTaskID: UIBackgroundTaskIdentifier
    ) {
        guard processingRunID == runID else { return }
        processingRunID = nil
        processingTask = nil
        processingSessionID = nil
        endBackgroundTask(backgroundTaskID)
        finishExpiredReadySessionIfPossible()
    }

    private func cancelProcessingTask() {
        let backgroundTaskID = processingBackgroundTaskID
        processingTask?.cancel()
        processingTask = nil
        processingRunID = nil
        processingSessionID = nil
        endBackgroundTask(backgroundTaskID)
    }

    private func expireProcessing(
        sessionID: String?,
        backgroundTaskID: UIBackgroundTaskIdentifier
    ) {
        guard processingSessionID == sessionID,
              processingBackgroundTaskID == backgroundTaskID else {
            bgLog.info("🎙 BG: ignored stale expiry for session \((sessionID ?? "-").prefix(8))")
            return
        }
        processingTask?.cancel()
        processingTask = nil
        processingRunID = nil
        processingSessionID = nil
        _ = writeError("Processing expired. Try again.", sessionID: sessionID)
        endBackgroundTask(backgroundTaskID)
        finishExpiredReadySessionIfPossible()
    }

    private func endBackgroundTask(_ bgTaskID: UIBackgroundTaskIdentifier) {
        guard bgTaskID != .invalid,
              processingBackgroundTaskID == bgTaskID else { return }
        runOnMainSync {
            MainActor.assumeIsolated {
                UIApplication.shared.endBackgroundTask(bgTaskID)
            }
        }
        processingBackgroundTaskID = .invalid
        if processingTask == nil, processingRunID == nil {
            processingSessionID = nil
        }
    }

    @MainActor
    private func persistKeyboardSession(
        processed: VoiceWorkflowProcessedResult,
        definition: WorkflowDefinition,
        destinationSummary: String
    ) {
        guard let modelContext else { return }
        let legacyModeID = WorkflowMigration.legacyModeID(forWorkflowID: definition.id)
        let session = DictationSession(
            date: Date(),
            workflowID: definition.id,
            workflowName: definition.name,
            mode: legacyModeID ?? definition.id,
            inputText: processed.rawText,
            outputText: processed.finalText,
            destination: destinationSummary,
            latencyMs: processed.timings.total * 1_000
        )
        modelContext.insert(session)
        do {
            try modelContext.save()
        } catch {
            bgLog.error("🎙 BG: history save failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Provider Resolution

    private func readAppConfig() -> AppConfig {
        AppConfigStorage.load() ?? WorkflowMigration.migrated(AppConfig())
    }

    private func resolveWorkflowID(config: AppConfig) -> String {
        let isRunnable: (String) -> Bool = { id in
            guard let definition = config.workflowCatalog.workflow(id: id) else { return false }
            return (try? VoiceWorkflowOperationalValidator.validateMicrophone(
                definition: definition,
                catalog: config.workflowCatalog,
                config: config
            )) != nil
        }
        if let workflowID = AppConfigStorage.keyboardWorkflowID(),
           isRunnable(workflowID) {
            return workflowID
        }
        if let legacyModeID = AppConfigStorage.keyboardModeID() {
            let workflowID = WorkflowMigration.workflowID(forLegacyModeID: legacyModeID)
            if isRunnable(workflowID) {
                return workflowID
            }
        }
        if isRunnable(config.activeVoiceWorkflowID) {
            return config.activeVoiceWorkflowID
        }
        return isRunnable("wf.dictation") ? "wf.dictation" : ""
    }

    private func compileKeyboardWorkflow(
        definition: WorkflowDefinition,
        catalog: WorkflowCatalog,
        config: AppConfig
    ) throws -> ResolvedVoiceWorkflow {
        let legacyScopeID = WorkflowMigration.legacyModeID(forWorkflowID: definition.id)
        let compilation = try VoiceWorkflowPlanFactory(
            config: config,
            vocabStore: VocabStore()
        ).compile(
            definition: definition,
            catalog: catalog,
            legacyScopeID: legacyScopeID,
            resolveOutput: { widget in
                switch widget.typeTag {
                case "insert", "return_to_caller": return ReturnToCallerVoiceWorkflowOutput()
                case "clipboard": return BackgroundClipboardVoiceWorkflowOutput()
                default:
                    throw VoiceWorkflowCompileError.unsupportedWidget(
                        widgetID: widget.id,
                        role: widget.role,
                        typeTag: widget.typeTag
                    )
                }
            }
        )
        return compilation.plan
    }

    // MARK: - File-based IPC

    private func writeFile(_ name: String, _ content: String) {
        guard let url = containerURL(name) else { return }
        try? content.write(to: url, atomically: true, encoding: .utf8)
    }

    private func readFile(_ name: String) -> String? {
        guard let url = containerURL(name) else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }

    private func deleteFile(_ name: String) {
        guard let url = containerURL(name) else { return }
        try? FileManager.default.removeItem(at: url)
    }

    private func resetKeyboardIPCForNewAppInstance() {
        resetKeyboardIPCForRecorderRestart()
        deleteFile(KeyboardIPC.FileName.cancelSessionID)
        bgLog.info("🎙 BG: reset keyboard IPC, appInstance=\(self.appInstanceID.prefix(8))")
    }

    private func resetKeyboardIPCForRecorderRestart() {
        writeFile(KeyboardIPC.FileName.appInstanceID, appInstanceID)
        clearKeyboardIPCResultFiles()
    }

    private func clearKeyboardIPCResultFiles() {
        deleteFile(KeyboardIPC.FileName.startAckSessionID)
        deleteFile(KeyboardIPC.FileName.resultSessionID)
        deleteFile(KeyboardIPC.FileName.delivery)
        deleteFile(KeyboardIPC.FileName.status)
        deleteFile(KeyboardIPC.FileName.partial)
        deleteFile(KeyboardIPC.FileName.final)
        deleteFile(KeyboardIPC.FileName.error)
    }

    private func writeStatus(_ status: String) {
        writeFile(KeyboardIPC.FileName.status, status)
        bgLog.info("🎙 BG: status → \(status)")
    }

    @discardableResult
    private func writeFinal(
        _ text: String,
        sessionID: String?,
        delivery: KeyboardIPC.Delivery = .insert
    ) -> Bool {
        guard sessionState.activeSessionID == sessionID else {
            bgLog.info("🎙 BG: ignored stale final for session \((sessionID ?? "-").prefix(8))")
            return false
        }
        writeFile(KeyboardIPC.FileName.final, text)
        writeFile(KeyboardIPC.FileName.delivery, delivery.rawValue)
        if let sessionID {
            writeFile(KeyboardIPC.FileName.resultSessionID, sessionID)
        }
        writeFile(KeyboardIPC.FileName.status, "done")
        bgLog.info("🎙 BG: wrote result (\(text.count) chars)")
        postDarwin(KeyboardIPC.NotificationName.result)
        sessionState.clearIfActive(sessionID: sessionID)
        return true
    }

    @discardableResult
    private func writeError(_ msg: String, sessionID: String?) -> Bool {
        guard sessionState.activeSessionID == sessionID else {
            bgLog.info("🎙 BG: ignored stale error for session \((sessionID ?? "-").prefix(8))")
            return false
        }
        writeFile(KeyboardIPC.FileName.error, msg)
        if let sessionID {
            writeFile(KeyboardIPC.FileName.resultSessionID, sessionID)
        }
        writeFile(KeyboardIPC.FileName.status, "error")
        bgLog.info("🎙 BG: wrote error: \(msg)")
        postDarwin(KeyboardIPC.NotificationName.result)
        sessionState.clearIfActive(sessionID: sessionID)
        return true
    }

    private func postDarwin(_ name: String) {
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName(name as CFString),
            nil, nil, true
        )
    }

    private func containerURL(_ filename: String) -> URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupID)?
            .appendingPathComponent(filename)
    }

    private func runOnMainSync(_ work: @escaping () -> Void) {
        if Thread.isMainThread {
            work()
        } else {
            DispatchQueue.main.sync(execute: work)
        }
    }
}
