import Foundation

/// App Group IPC client for keyboard dictation.
///
/// Apple doesn't give custom keyboard extensions microphone access, even with
/// Full Access. Audio capture and the complete workflow therefore belong to
/// the containing app; the extension only sends session-scoped commands and
/// consumes the resulting text.
final class KeyboardAudioService: NSObject, @unchecked Sendable {
    private(set) var isRecording = false

    // File-based App Group IPC; UserDefaults notifications aren't reliable
    // enough for cross-process command delivery.
    private let groupID = KeyboardIPC.appGroupID
    private var pollTimer: Timer?
    private var observersRegistered = false
    private var sessionTracker = KeyboardIPCSessionTracker()
    private var activeAppInstanceID: String?
    private var activeReadySessionID: String?

    var activeSessionID: String? { sessionTracker.currentSessionID }

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
        tryAppGroupRecording(completion: completion)
    }

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

    // MARK: - App Group session

    private func tryAppGroupRecording(completion: @escaping (Error?) -> Void) {
        guard containerURL != nil else {
            completion(makeError("App Group container not accessible"))
            return
        }

        // Check heartbeat
        let heartbeatStr = readFile(KeyboardIPC.FileName.heartbeat) ?? "0"
        let heartbeat = Double(heartbeatStr) ?? 0
        let appInstanceID = readFile(KeyboardIPC.FileName.appInstanceID) ?? ""
        let readinessStatus = readFile(KeyboardIPC.FileName.readinessStatus)
            .flatMap(KeyboardIPC.ReadinessStatus.init(rawValue:))
        let readySessionID = readFile(KeyboardIPC.FileName.readySessionID) ?? ""
        let readyExpiresAt = Double(
            readFile(KeyboardIPC.FileName.readyExpiresAt) ?? "0"
        ) ?? 0
        let now = Date().timeIntervalSince1970
        let age = now - heartbeat
        diag("heartbeat: \(String(format: "%.1f", age))s ago, app=\(appInstanceID.prefix(8)), ready=\(readinessStatus?.rawValue ?? "missing")")

        if !KeyboardIPC.hasReadyApp(
            heartbeat: heartbeat,
            appInstanceID: appInstanceID,
            readinessStatus: readinessStatus,
            readySessionID: readySessionID,
            readyExpiresAt: readyExpiresAt,
            now: now
        ) {
            completion(makeError(readinessErrorMessage(
                status: readinessStatus,
                readyExpiresAt: readyExpiresAt,
                now: now
            )))
            return
        }

        // Clear old state
        clearIPCFiles()

        let sessionID = UUID().uuidString
        sessionTracker.begin(sessionID: sessionID)
        activeAppInstanceID = appInstanceID
        activeReadySessionID = readySessionID
        writeFile(KeyboardIPC.FileName.sessionID, sessionID)

        registerObserversIfNeeded()

        // Send start command after observers/session are in place.
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName(KeyboardIPC.NotificationName.start as CFString),
            nil, nil, true
        )
        diag("sent start notification, session=\(sessionID.prefix(8))")

        // Poll files every 0.1s as backup for missed Darwin notifications.
        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            self?.pollFiles()
        }

        isRecording = true
        diag("✅ App Group, waiting for main app...")
        completion(nil)

        // Start ack: stale heartbeats can survive briefly after the app is killed.
        // The current app process must acknowledge this exact session quickly.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            guard let self,
                  self.isRecording,
                  self.sessionTracker.currentSessionID == sessionID else { return }
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
        deleteFile(KeyboardIPC.FileName.delivery)
    }

    private func registerObserversIfNeeded() {
        guard !observersRegistered else { return }
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        let observer = Unmanaged.passUnretained(self).toOpaque()

        CFNotificationCenterAddObserver(center, observer, { _, obs, _, _, _ in
            guard let obs else { return }
            Unmanaged<KeyboardAudioService>.fromOpaque(obs).takeUnretainedValue().onPartialReceived()
        }, KeyboardIPC.NotificationName.partial as CFString, nil, .deliverImmediately)

        CFNotificationCenterAddObserver(center, observer, { _, obs, _, _, _ in
            guard let obs else { return }
            Unmanaged<KeyboardAudioService>.fromOpaque(obs).takeUnretainedValue().onResultReceived()
        }, KeyboardIPC.NotificationName.result as CFString, nil, .deliverImmediately)

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
                let delivery = KeyboardIPC.resolvedDelivery(
                    readFile(KeyboardIPC.FileName.delivery)
                )
                diag("✅ got result: \"\(text.prefix(40))...\"")
                onStatusChange?(KeyboardIPC.callbackStatus(text: text, delivery: delivery))
            } else if status == "error" {
                sessionTracker.markResultHandled()
                let err = readFile(KeyboardIPC.FileName.error) ?? "Unknown error"
                diag("❌ got error: \(err)")
                onStatusChange?("error:\(err)")
            }
        }
    }

    private func pollFiles() {
        guard sessionTracker.hasActiveSession else { return }
        let heartbeat = Double(readFile(KeyboardIPC.FileName.heartbeat) ?? "0") ?? 0
        let appInstanceID = readFile(KeyboardIPC.FileName.appInstanceID) ?? ""
        let readySessionID = readFile(KeyboardIPC.FileName.readySessionID) ?? ""
        let status = readFile(KeyboardIPC.FileName.status) ?? ""
        let statusChange = onStatusChange

        // A completed operation may tear down an expired Ready window right
        // after publishing its result. Consume the terminal payload before
        // checking heartbeat or Ready-session identity.
        if status == "done" || status == "error" {
            onResultReceived()
            return
        }
        if activeAppInstanceID != nil && !KeyboardIPC.isSameAppInstance(activeAppInstanceID, current: appInstanceID) {
            diag("app instance changed while waiting: \((activeAppInstanceID ?? "-").prefix(8)) → \(appInstanceID.prefix(8))")
            isRecording = false
            cleanup()
            statusChange?("error:Fonos app reconnected. Tap the mic and try again.")
            return
        }

        if activeReadySessionID != nil,
           !KeyboardIPC.isSameAppInstance(activeReadySessionID, current: readySessionID) {
            diag("ready session changed while waiting")
            isRecording = false
            cleanup()
            statusChange?("error:Keyboard Ready ended in Fonos.")
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

        if status == "recording" {
            if let text = readFile(KeyboardIPC.FileName.partial), !text.isEmpty {
                DispatchQueue.main.async { [self] in onPartialResult?(text) }
            }
        }
    }

    // MARK: - Stop Recording

    func stopRecording() {
        guard isRecording else { return }

        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName(KeyboardIPC.NotificationName.stop as CFString),
            nil, nil, true
        )
        diag("sent stop to main app")

        isRecording = false
    }

    // MARK: - Cleanup

    func cleanup() {
        cancelActiveProducerSession()
        pollTimer?.invalidate()
        pollTimer = nil
        deleteFile(KeyboardIPC.FileName.delivery)
        sessionTracker.clear()
        activeAppInstanceID = nil
        activeReadySessionID = nil
        isRecording = false

        // Remove Darwin notification observers
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        CFNotificationCenterRemoveEveryObserver(center, Unmanaged.passUnretained(self).toOpaque())
        observersRegistered = false

        onPartialResult = nil
        onStatusChange = nil
    }

    /// File payload supplies identity because Darwin notifications carry no
    /// user info. The main app consumes this only if it still owns the same
    /// session, making late timeout/keyboard-dismiss cleanup harmless.
    private func cancelActiveProducerSession() {
        guard let sessionID = sessionTracker.cancellationSessionID else { return }
        writeFile(KeyboardIPC.FileName.cancelSessionID, sessionID)
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName(KeyboardIPC.NotificationName.cancel as CFString),
            nil, nil, true
        )
        diag("sent cancel for session=\(sessionID.prefix(8))")
    }

    private func makeError(_ msg: String) -> NSError {
        diag("❌ \(msg)")
        return NSError(domain: "KB", code: 1, userInfo: [NSLocalizedDescriptionKey: msg])
    }

    private func readinessErrorMessage(
        status: KeyboardIPC.ReadinessStatus?,
        readyExpiresAt: Double,
        now: Double
    ) -> String {
        if status == .paused {
            return "Fonos is using the microphone. Finish there, then try again."
        }
        if status == .finishing {
            return "The previous dictation is finishing. Open Fonos to renew Keyboard Ready."
        }
        if status == .expired || (readyExpiresAt > 0 && readyExpiresAt <= now) {
            return "Keyboard Ready expired. Open Fonos to enable it again."
        }
        return "Open Fonos and enable Keyboard Ready, then return here."
    }
}
