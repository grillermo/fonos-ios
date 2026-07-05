import UIKit
import AVFoundation
import Speech
import os.log

private let bgLog = Logger(subsystem: "com.fonos.ios", category: "BackgroundRec")

/// Background recording service for keyboard extension.
///
/// Strategy: Start AVAudioRecorder while app is in FOREGROUND (on launch).
/// iOS allows audio to CONTINUE in background but not START.
/// When keyboard requests recording, we mark timestamps and extract the segment.
final class BackgroundRecordingService: NSObject, @unchecked Sendable {
    static let shared = BackgroundRecordingService()

    private let groupID = "group.com.fonos.ios"

    // Continuous recorder — started in foreground, runs in background
    private var recorder: AVAudioRecorder?
    private var recordingStartTime: TimeInterval = 0
    private var recordingStartDate = Date()
    private var isKeyboardRecording = false
    private var sessionState = KeyboardIPCProducerSessionState()
    private let appInstanceID = UUID().uuidString

    private static nonisolated(unsafe) let kbStart = "com.fonos.ios.kb.start" as CFString
    private static nonisolated(unsafe) let kbStop  = "com.fonos.ios.kb.stop" as CFString

    private override init() { super.init() }

    // MARK: - Registration (called on app launch, while in FOREGROUND)

    func register() {
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

        // Verify App Group
        if let url = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupID) {
            bgLog.info("✅ App Group: \(url.path)")
        } else {
            bgLog.error("❌ App Group NOT accessible!")
        }

        // Configure + activate audio session (MUST happen in foreground)
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .default, options: [.mixWithOthers, .allowBluetoothHFP])
            try session.setActive(true, options: .notifyOthersOnDeactivation)
            bgLog.info("✅ Audio session active")
        } catch {
            bgLog.error("❌ Audio session: \(error.localizedDescription)")
        }

        // Start continuous recording — runs in background with audio background mode
        startContinuousRecording()
        resetKeyboardIPCForNewAppInstance()

        // Heartbeat — also checks recorder health
        updateHeartbeat()
        Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.updateHeartbeat()
        }

        // Restart recorder when app comes to foreground
        NotificationCenter.default.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            if self.recorder == nil || self.recorder?.isRecording != true {
                bgLog.info("🎙 BG: App foregrounded, restarting recorder")
                self.startContinuousRecording()
            }
        }

        // Handle audio interruptions (phone calls, other apps)
        NotificationCenter.default.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] notification in
            guard let self,
                  let info = notification.userInfo,
                  let typeValue = info[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: typeValue) else { return }

            if type == .began {
                bgLog.info("🎙 BG: Audio interrupted")
            } else if type == .ended {
                bgLog.info("🎙 BG: Interruption ended")
                try? AVAudioSession.sharedInstance().setActive(true, options: .notifyOthersOnDeactivation)
                // Resume EXISTING recorder (don't create new — new fails from background)
                if let rec = self.recorder, rec.record() {
                    bgLog.info("🎙 BG: ✅ Recorder resumed after interruption")
                } else {
                    bgLog.warning("🎙 BG: Resume failed, will restart when app foregrounded")
                    // Can't start new recorder from background — will restart on foreground
                }
            }
        }

        bgLog.info("✅ BackgroundRecordingService registered")
    }

    // MARK: - Continuous Recording

    private func startContinuousRecording() {
        guard let url = containerURL(KeyboardIPC.FileName.continuousAudio) else { return }
        try? FileManager.default.removeItem(at: url)

        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatLinearPCM),
            AVSampleRateKey: 16000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ]

        do {
            let rec = try AVAudioRecorder(url: url, settings: settings)
            rec.isMeteringEnabled = true
            if rec.record() {
                recorder = rec
                bgLog.info("🎙 Continuous recording started (keeps audio alive in background)")
            } else {
                bgLog.error("❌ Continuous recorder.record() failed")
            }
        } catch {
            bgLog.error("❌ Recorder init: \(error.localizedDescription)")
        }
    }

    // MARK: - Keyboard Start (just marks timestamp — recorder already running)

    private func onStart() {
        DispatchQueue.main.async { [self] in
            sessionState.begin(sessionID: readFile(KeyboardIPC.FileName.sessionID))
            guard let rec = recorder, rec.isRecording else {
                bgLog.error("🎙 BG: Recorder not active! Open Fonos app to restart.")
                writeError("Recorder stopped. Open Fonos app, then try again.",
                           sessionID: sessionState.captureForResult())
                return
            }

            rec.updateMeters()
            if isKeyboardRecording {
                bgLog.warning("🎙 BG: Previous keyboard recording was still active; resetting to new session")
            }
            recordingStartTime = rec.currentTime
            recordingStartDate = Date()
            isKeyboardRecording = true
            if let sessionID = sessionState.activeSessionID {
                writeFile(KeyboardIPC.FileName.startAckSessionID, sessionID)
            }
            writeStatus("recording")
            bgLog.info("🎙 BG: ✅ Keyboard recording started at \(String(format: "%.2f", self.recordingStartTime))s, session=\((self.sessionState.activeSessionID ?? "-").prefix(8))")
        }
    }

    // MARK: - Keyboard Stop (extracts segment, transcribes)

    private func onStop() {
        DispatchQueue.main.async { [self] in
            guard isKeyboardRecording, let rec = recorder else {
                bgLog.warning("Not keyboard-recording, ignoring stop")
                sessionState.begin(sessionID: readFile(KeyboardIPC.FileName.sessionID))
                writeError("Recording state expired. Tap the mic and try again.",
                           sessionID: sessionState.captureForResult())
                return
            }

            rec.updateMeters()
            let sessionID = sessionState.captureForResult()
            let startRecorderTime = recordingStartTime
            let stopWallClock = Date()
            let stopRecorderTime = rec.currentTime
            isKeyboardRecording = false
            let wallDuration = max(0, stopWallClock.timeIntervalSince(recordingStartDate))
            bgLog.info("🎙 BG: Stop requested. Wall duration=\(String(format: "%.2f", wallDuration))s")

            // Background task for transcription
            let bgTaskID = UIApplication.shared.beginBackgroundTask {
                bgLog.warning("🎙 BG: Background task expiring")
            }

            writeStatus("processing")

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [self] in
                finishStop(recorder: rec, sessionID: sessionID, startRecorderTime: startRecorderTime,
                           stopRecorderTime: stopRecorderTime, wallDuration: wallDuration,
                           bgTaskID: bgTaskID)
            }
        }
    }

    private func finishStop(recorder rec: AVAudioRecorder, sessionID: String?,
                            startRecorderTime: TimeInterval, stopRecorderTime: TimeInterval,
                            wallDuration: TimeInterval, bgTaskID: UIBackgroundTaskIdentifier) {
        rec.updateMeters()
        let endTime = max(stopRecorderTime, rec.currentTime)
        let recorderDuration = endTime - startRecorderTime
        bgLog.info("🎙 BG: Recorder segment: \(String(format: "%.2f", startRecorderTime))s → \(String(format: "%.2f", endTime))s, duration=\(String(format: "%.2f", recorderDuration))s, session=\((sessionID ?? "-").prefix(8))")

        guard let url = containerURL(KeyboardIPC.FileName.continuousAudio),
              let fullData = try? Data(contentsOf: url) else {
            writeError("Cannot read audio", sessionID: sessionID)
            endBackgroundTask(bgTaskID)
            return
        }

        let byTail = WAVSegment.tail(fullData, duration: wallDuration + 0.25, sampleRate: 16000)
        let byTime = WAVSegment.segment(fullData, from: startRecorderTime, to: endTime, sampleRate: 16000)
        let wavData = byTime.count > 100 ? byTime : byTail
        let effectiveDuration = max(wallDuration, recorderDuration)

        bgLog.info("🎙 BG: Extracted segment bytes=\(wavData.count), byTime=\(byTime.count), byTail=\(byTail.count), full=\(fullData.count), recorderStillRunning=\(rec.isRecording)")

        guard effectiveDuration >= 0.4, wavData.count > 100 else {
            writeError("No audio captured. Open Fonos, then try again.", sessionID: sessionID)
            endBackgroundTask(bgTaskID)
            return
        }

        // Save extracted segment for STT
        if let segURL = containerURL(KeyboardIPC.FileName.segmentAudio) {
            try? wavData.write(to: segURL)
        }

        transcribeAndProcess(wavData: wavData, sessionID: sessionID, bgTaskID: bgTaskID)
    }

    private func updateHeartbeat() {
        let now = "\(Date().timeIntervalSince1970)"
        guard let rec = recorder else {
            writeFile(KeyboardIPC.FileName.heartbeat, "0")
            return
        }

        if rec.isRecording {
            writeFile(KeyboardIPC.FileName.appInstanceID, appInstanceID)
            writeFile(KeyboardIPC.FileName.heartbeat, now)
        } else if !isKeyboardRecording, rec.record() {
            bgLog.info("🎙 BG: Recorder auto-resumed")
            writeFile(KeyboardIPC.FileName.appInstanceID, appInstanceID)
            writeFile(KeyboardIPC.FileName.heartbeat, now)
        } else {
            bgLog.warning("🎙 BG: Recorder not ready; heartbeat withheld")
            writeFile(KeyboardIPC.FileName.heartbeat, "0")
        }
    }

    // WAV byte-slicing lives in WAVSegment (pure + unit-tested — it must read
    // the growing file to its real end, not the declared-0 data-chunk size).

    // MARK: - Transcribe & Process

    private func transcribeAndProcess(wavData: Data, sessionID: String?,
                                      bgTaskID: UIBackgroundTaskIdentifier) {
        let config = readAppConfig()
        let sttProvider = resolveSTTProvider(config: config)
        let mode = resolveMode(config: config)
        let language = config.sttLanguage == "auto" ? nil : config.sttLanguage

        // Vocab context (same pipeline as the Dictate/Notes surfaces): bias STT,
        // apply deterministic corrections, and pass the glossary to the LLM.
        let vocab = VocabStore().context(modeID: mode.id)
        let promptHint = config.modeConfigs.first(where: { $0.id == mode.id })?.sttPrompt ?? ""

        bgLog.info("🎙 BG: STT=\(type(of: sttProvider)), mode=\(mode.displayName), vocabTerms=\(vocab.terms.count)")

        Task {
            do {
                let sttText = try await sttProvider.transcribe(
                    audioData: wavData, language: language,
                    vocabulary: vocab.terms, promptHint: promptHint
                )
                let rawTranscript = vocab.correct(sttText)
                bgLog.info("🎙 BG: Transcript: \"\(rawTranscript.prefix(50))...\"")

                var finalText = rawTranscript
                if mode.requiresLLM, let llm = resolveLLMService(config: config) {
                    bgLog.info("🎙 BG: LLM (\(mode.displayName))...")
                    finalText = (try? await llm.process(text: rawTranscript, mode: mode, glossary: vocab.glossary)) ?? rawTranscript
                }

                writeFinal(finalText, sessionID: sessionID)
                bgLog.info("🎙 BG: ✅ Done: \"\(finalText.prefix(50))...\", session=\((sessionID ?? "-").prefix(8))")
            } catch {
                bgLog.error("🎙 BG: ❌ STT failed: \(error.localizedDescription)")
                writeError("STT: \(error.localizedDescription)", sessionID: sessionID)
            }
            self.endBackgroundTask(bgTaskID)
        }
    }

    private func endBackgroundTask(_ bgTaskID: UIBackgroundTaskIdentifier) {
        if bgTaskID != .invalid {
            UIApplication.shared.endBackgroundTask(bgTaskID)
        }
    }

    // MARK: - Provider Resolution

    private func readAppConfig() -> AppConfig {
        AppConfigStorage.load() ?? AppConfig()
    }

    private func resolveSTTProvider(config: AppConfig) -> any STTProvider {
        let profileID = config.sttProfile
        guard !profileID.isEmpty,
              let profile = config.modelProfiles.first(where: { $0.id == profileID }) else {
            return AppleSTT()
        }
        let key = (try? KeychainStore(service: "com.fonos.models").get(profile.id)) ?? ""
        let baseURL = profile.baseURL ?? ""
        if profile.hasSTT && !baseURL.isEmpty {
            return WhisperSTT(apiKey: key, baseURL: baseURL, modelID: profile.modelID)
        }
        return AppleSTT()
    }

    private func resolveLLMService(config: AppConfig) -> LLMService? {
        let profileID = config.llmProfile
        guard !profileID.isEmpty,
              let profile = config.modelProfiles.first(where: { $0.id == profileID }) else {
            return nil
        }
        let key = (try? KeychainStore(service: "com.fonos.models").get(profile.id)) ?? ""
        let baseURL = profile.baseURL ?? ""
        return LLMService(apiKey: key, modelID: profile.modelID, baseURL: baseURL.isEmpty ? "https://api.openai.com" : baseURL)
    }

    /// The background recorder only ever serves keyboard dictations, so it uses
    /// the keyboard's own mode (kb_active_mode_id), falling back to the main
    /// app's mode until the keyboard has picked one.
    private func resolveMode(config: AppConfig) -> Mode {
        let modeID = AppConfigStorage.resolveKeyboardMode(
            override: AppConfigStorage.keyboardModeID(),
            configActiveModeID: config.activeModeID
        )

        if let modeConfig = config.modeConfigs.first(where: { $0.id == modeID }) {
            switch modeConfig.mode {
            case .translate:
                return .translate(targetLanguage: config.translateTargetLanguage)
            default:
                return modeConfig.mode
            }
        }

        switch modeID {
        case "polish": return .polish
        case "formal": return .formal
        case "translate": return .translate(targetLanguage: config.translateTargetLanguage)
        default: return .raw
        }
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
        writeFile(KeyboardIPC.FileName.appInstanceID, appInstanceID)
        deleteFile(KeyboardIPC.FileName.startAckSessionID)
        deleteFile(KeyboardIPC.FileName.resultSessionID)
        deleteFile(KeyboardIPC.FileName.status)
        deleteFile(KeyboardIPC.FileName.partial)
        deleteFile(KeyboardIPC.FileName.final)
        deleteFile(KeyboardIPC.FileName.error)
        bgLog.info("🎙 BG: reset keyboard IPC, appInstance=\(self.appInstanceID.prefix(8))")
    }

    private func writeStatus(_ status: String) {
        writeFile(KeyboardIPC.FileName.status, status)
        bgLog.info("🎙 BG: status → \(status)")
    }

    private func writeFinal(_ text: String, sessionID: String?) {
        writeFile(KeyboardIPC.FileName.final, text)
        if let sessionID {
            writeFile(KeyboardIPC.FileName.resultSessionID, sessionID)
        }
        writeFile(KeyboardIPC.FileName.status, "done")
        bgLog.info("🎙 BG: wrote result (\(text.count) chars)")
        postDarwin("com.fonos.ios.kb.result")
        sessionState.clearIfActive(sessionID: sessionID)
    }

    private func writeError(_ msg: String, sessionID: String?) {
        writeFile(KeyboardIPC.FileName.error, msg)
        if let sessionID {
            writeFile(KeyboardIPC.FileName.resultSessionID, sessionID)
        }
        writeFile(KeyboardIPC.FileName.status, "error")
        bgLog.info("🎙 BG: wrote error: \(msg)")
        postDarwin("com.fonos.ios.kb.result")
        sessionState.clearIfActive(sessionID: sessionID)
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
}
