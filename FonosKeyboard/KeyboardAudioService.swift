import AVFoundation
import Speech

private struct UncheckedSendableBox<T>: @unchecked Sendable {
    let value: T
    init(_ value: T) { self.value = value }
}

/// Keyboard extension audio service with two strategies:
///
/// Strategy 1: AVAudioRecorder (try first — may work with paid developer account)
///   Records directly in keyboard extension → transcribes with SFSpeechURLRecognitionRequest.
///
/// Strategy 2: App Group IPC (fallback — always works)
///   Keyboard sends command → Main app records in background → Result via shared UserDefaults.
///   Supports third-party STT (Whisper, OMLX) and LLM processing because the main app handles everything.
final class KeyboardAudioService: NSObject, @unchecked Sendable {

    enum Strategy {
        case direct       // AVAudioRecorder in keyboard extension
        case appGroup     // Main app records via App Group IPC
    }

    private(set) var isRecording = false
    private(set) var activeStrategy: Strategy?

    // Strategy 1: Direct recording
    private var recorder: AVAudioRecorder?
    private var recordingURL: URL?

    // Strategy 2: App Group IPC (file-based — UserDefaults unreliable cross-process)
    private let groupID = "group.com.fonos.ios"
    private var pollTimer: Timer?
    private var observersRegistered = false
    private var sessionTracker = KeyboardIPCSessionTracker()
    private var activeAppInstanceID: String?

    private var containerURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupID)
    }

    // Callbacks
    private var onPartialResult: ((String) -> Void)?
    private var onStatusChange: ((String) -> Void)?

    // Diagnostics
    private(set) var diagnosticLog: [String] = []

    func diag(_ msg: String) {
        print("🎙 KB: \(msg)")
        diagnosticLog.append(msg)
    }

    override init() { super.init() }

    // MARK: - Start Recording

    func startRecording(
        onPartial: @escaping (String) -> Void,
        onStatus: @escaping (String) -> Void,
        completion: @escaping (Error?) -> Void
    ) {
        guard !isRecording else { completion(nil); return }
        cleanup()
        diagnosticLog = []
        onPartialResult = onPartial
        onStatusChange = onStatus

        let session = AVAudioSession.sharedInstance()
        let perm = session.recordPermission
        diag("perm=\(perm == .granted ? "granted" : perm == .denied ? "DENIED" : "undetermined")")

        if perm == .denied {
            completion(makeError("Mic DENIED — Settings → Privacy → Microphone"))
            return
        }

        // Wrap completion to satisfy Sendable requirement of requestRecordPermission
        let completionBox = UncheckedSendableBox(completion)
        session.requestRecordPermission { [self] granted in
            let comp = completionBox.value
            diag("micReq → \(granted)")
            DispatchQueue.main.async {
                guard granted else {
                    comp(self.makeError("Mic denied"))
                    return
                }
                // Skip direct recording — keyboard extensions can't capture audio,
                // and trying activates an audio session that KILLS the main app's recorder.
                self.tryAppGroupRecording(completion: comp)
            }
        }
    }

    // MARK: - Strategy 1: AVAudioRecorder (Direct)

    private func tryDirectRecording(completion: @escaping (Error?) -> Void) {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .voiceChat, options: [.mixWithOthers, .allowBluetoothHFP])
            try session.setActive(true, options: .notifyOthersOnDeactivation)
            diag("session OK")
        } catch {
            diag("session err: \(error.localizedDescription)")
        }

        let url = FileManager.default.temporaryDirectory.appendingPathComponent("kb_rec.wav")
        try? FileManager.default.removeItem(at: url)
        recordingURL = url

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
                isRecording = true
                activeStrategy = .direct
                diag("✅ AVAudioRecorder works!")
                completion(nil)
                return
            }
            diag("recorder.record()=false")
        } catch {
            diag("recorder err: \(error.localizedDescription)")
        }

        // Strategy 1 failed → try Strategy 2
        diag("→ falling back to App Group")
        tryAppGroupRecording(completion: completion)
    }

    // MARK: - Strategy 2: App Group IPC

    // MARK: - File-based IPC helpers

    private func readFile(_ name: String) -> String? {
        guard let url = containerURL?.appendingPathComponent(name) else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }

    private func writeFile(_ name: String, _ content: String) {
        guard let url = containerURL?.appendingPathComponent(name) else { return }
        try? content.write(to: url, atomically: true, encoding: .utf8)
    }

    private func deleteFile(_ name: String) {
        guard let url = containerURL?.appendingPathComponent(name) else { return }
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: - Strategy 2: App Group IPC

    private func tryAppGroupRecording(completion: @escaping (Error?) -> Void) {
        guard containerURL != nil else {
            completion(makeError("App Group container not accessible"))
            return
        }

        // Check heartbeat
        let heartbeatStr = readFile(KeyboardIPC.FileName.heartbeat) ?? "0"
        let heartbeat = Double(heartbeatStr) ?? 0
        let appInstanceID = readFile(KeyboardIPC.FileName.appInstanceID) ?? ""
        let now = Date().timeIntervalSince1970
        let age = now - heartbeat
        diag("heartbeat: \(String(format: "%.1f", age))s ago, app=\(appInstanceID.prefix(8))")

        if !KeyboardIPC.hasLiveApp(heartbeat: heartbeat, appInstanceID: appInstanceID, now: now) {
            completion(makeError("Fonos app not running.\nOpen Fonos app, keep it open, then try again."))
            return
        }

        // Clear old state
        clearIPCFiles()

        let sessionID = UUID().uuidString
        sessionTracker.begin(sessionID: sessionID)
        activeAppInstanceID = appInstanceID
        writeFile(KeyboardIPC.FileName.sessionID, sessionID)

        registerObserversIfNeeded()

        // Send start command after observers/session are in place.
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName("com.fonos.ios.kb.start" as CFString),
            nil, nil, true
        )
        diag("sent start notification, session=\(sessionID.prefix(8))")

        // Poll files every 0.1s as backup for missed Darwin notifications.
        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            self?.pollFiles()
        }

        isRecording = true
        activeStrategy = .appGroup
        diag("✅ App Group, waiting for main app...")
        completion(nil)

        // Start ack: stale heartbeats can survive briefly after the app is killed.
        // The current app process must acknowledge this exact session quickly.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            guard let self, self.isRecording, self.activeStrategy == .appGroup else { return }
            let ack = self.readFile(KeyboardIPC.FileName.startAckSessionID)
            if ack == sessionID { return }
            let status = self.readFile(KeyboardIPC.FileName.status) ?? ""
            if status != "recording" && status != "processing" && status != "done" {
                let statusChange = self.onStatusChange
                self.isRecording = false
                self.cleanup()
                statusChange?("error:Fonos app is not connected. Open Fonos app, then try again.")
            }
        }
    }

    private func clearIPCFiles() {
        deleteFile(KeyboardIPC.FileName.status)
        deleteFile(KeyboardIPC.FileName.partial)
        deleteFile(KeyboardIPC.FileName.final)
        deleteFile(KeyboardIPC.FileName.error)
        deleteFile(KeyboardIPC.FileName.startAckSessionID)
        deleteFile(KeyboardIPC.FileName.resultSessionID)
    }

    private func registerObserversIfNeeded() {
        guard !observersRegistered else { return }
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        let observer = Unmanaged.passUnretained(self).toOpaque()

        CFNotificationCenterAddObserver(center, observer, { _, obs, _, _, _ in
            guard let obs else { return }
            Unmanaged<KeyboardAudioService>.fromOpaque(obs).takeUnretainedValue().onPartialReceived()
        }, "com.fonos.ios.kb.partial" as CFString, nil, .deliverImmediately)

        CFNotificationCenterAddObserver(center, observer, { _, obs, _, _, _ in
            guard let obs else { return }
            Unmanaged<KeyboardAudioService>.fromOpaque(obs).takeUnretainedValue().onResultReceived()
        }, "com.fonos.ios.kb.result" as CFString, nil, .deliverImmediately)

        observersRegistered = true
    }

    private func onPartialReceived() {
        DispatchQueue.main.async { [self] in
            if let text = readFile(KeyboardIPC.FileName.partial), !text.isEmpty {
                onPartialResult?(text)
            }
        }
    }

    private func onResultReceived() {
        DispatchQueue.main.async { [self] in
            let resultSessionID = readFile(KeyboardIPC.FileName.resultSessionID)
            guard sessionTracker.accepts(resultSessionID: resultSessionID) else {
                if resultSessionID != nil {
                    diag("ignored stale result for session=\((resultSessionID ?? "").prefix(8))")
                }
                return
            }
            let status = readFile(KeyboardIPC.FileName.status) ?? ""

            if status == "done" {
                sessionTracker.markResultHandled()
                let text = readFile(KeyboardIPC.FileName.final) ?? ""
                diag("✅ got result: \"\(text.prefix(40))...\"")
                onStatusChange?("done:\(text)")
            } else if status == "error" {
                sessionTracker.markResultHandled()
                let err = readFile(KeyboardIPC.FileName.error) ?? "Unknown error"
                diag("❌ got error: \(err)")
                onStatusChange?("error:\(err)")
            }
        }
    }

    private func pollFiles() {
        guard activeStrategy == .appGroup, sessionTracker.hasActiveSession else { return }
        let heartbeat = Double(readFile(KeyboardIPC.FileName.heartbeat) ?? "0") ?? 0
        let appInstanceID = readFile(KeyboardIPC.FileName.appInstanceID) ?? ""
        let statusChange = onStatusChange
        if activeAppInstanceID != nil && !KeyboardIPC.isSameAppInstance(activeAppInstanceID, current: appInstanceID) {
            diag("app instance changed while waiting: \((activeAppInstanceID ?? "-").prefix(8)) → \(appInstanceID.prefix(8))")
            isRecording = false
            cleanup()
            statusChange?("error:Fonos app reconnected. Tap the mic and try again.")
            return
        }

        if !KeyboardIPC.hasLiveApp(heartbeat: heartbeat, appInstanceID: appInstanceID,
                                   now: Date().timeIntervalSince1970) {
            diag("heartbeat stale while waiting for app response")
            isRecording = false
            cleanup()
            statusChange?("error:Fonos app stopped. Open Fonos app, then try again.")
            return
        }

        let status = readFile(KeyboardIPC.FileName.status) ?? ""

        if status == "recording" {
            if let text = readFile(KeyboardIPC.FileName.partial), !text.isEmpty {
                DispatchQueue.main.async { [self] in onPartialResult?(text) }
            }
        } else if status == "done" || status == "error" {
            onResultReceived()
        }
    }

    // MARK: - Stop Recording

    func stopRecording() {
        guard isRecording else { return }

        switch activeStrategy {
        case .direct:
            recorder?.stop()
            recorder = nil
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)

        case .appGroup:
            // Tell main app to stop via Darwin notification
            CFNotificationCenterPostNotification(
                CFNotificationCenterGetDarwinNotifyCenter(),
                CFNotificationName("com.fonos.ios.kb.stop" as CFString),
                nil, nil, true
            )
            diag("sent stop to main app")

        case .none:
            break
        }

        isRecording = false
    }

    // MARK: - Transcribe (Strategy 1 only — direct recording)

    func transcribeDirectRecording(language: String?, completion: @escaping (String?, Error?) -> Void) {
        guard let url = recordingURL, FileManager.default.fileExists(atPath: url.path) else {
            completion(nil, makeError("No recording file"))
            return
        }

        let fileSize = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        diag("file: \(fileSize)B")
        guard fileSize > 100 else {
            completion(nil, makeError("Too short (\(fileSize)B)"))
            return
        }

        SFSpeechRecognizer.requestAuthorization { [self] status in
            guard status == .authorized else {
                completion(nil, makeError("Speech denied"))
                return
            }

            let locale = language.map { Locale(identifier: $0) } ?? .current
            guard let recognizer = SFSpeechRecognizer(locale: locale)
                    ?? SFSpeechRecognizer(locale: Locale(identifier: "en-US")) else {
                completion(nil, makeError("No recognizer"))
                return
            }

            let request = SFSpeechURLRecognitionRequest(url: url)
            var done = false
            recognizer.recognitionTask(with: request) { [self] result, error in
                guard !done else { return }
                if let error {
                    done = true
                    completion(nil, error)
                    return
                }
                if let result, result.isFinal {
                    done = true
                    let text = result.bestTranscription.formattedString
                    diag("transcribed: \"\(text.prefix(30))...\"")
                    completion(text.isEmpty ? nil : text, nil)
                }
            }
        }
    }

    // MARK: - Cleanup

    func cleanup() {
        pollTimer?.invalidate()
        pollTimer = nil
        sessionTracker.clear()
        activeAppInstanceID = nil

        // Remove Darwin notification observers
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        CFNotificationCenterRemoveEveryObserver(center, Unmanaged.passUnretained(self).toOpaque())
        observersRegistered = false

        onPartialResult = nil
        onStatusChange = nil
    }

    private func makeError(_ msg: String) -> NSError {
        diag("❌ \(msg)")
        return NSError(domain: "KB", code: 1, userInfo: [NSLocalizedDescriptionKey: msg])
    }
}
