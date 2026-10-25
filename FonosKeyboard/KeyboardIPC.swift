import Foundation

enum KeyboardIPC {
    static let appGroupID = "group.me.chiq.fonos"

    enum DefaultsKey {
        static let appConfig = "app_config"
        static let modeOverride = "kb_active_mode_id"
        static let workflowOverride = "kb_active_workflow_id"
        static let workflowManifest = "kb_workflow_manifest_v1"
    }

    enum FileName {
        static let heartbeat = "kb_heartbeat"
        static let sessionID = "kb_session_id"
        static let startAckSessionID = "kb_start_ack_session_id"
        static let resultSessionID = "kb_result_session_id"
        static let cancelSessionID = "kb_cancel_session_id"
        static let delivery = "kb_delivery"
        static let appInstanceID = "kb_app_instance_id"
        static let readinessStatus = "kb_readiness_status"
        static let readySessionID = "kb_ready_session_id"
        static let readyExpiresAt = "kb_ready_expires_at"
        static let status = "kb_status"
        static let partial = "kb_partial.txt"
        static let final = "kb_final.txt"
        static let error = "kb_error.txt"
        // Upgrade cleanup only. Current Keyboard Ready capture is in memory.
        static let continuousAudio = "kb_continuous.wav"
        static let segmentAudio = "kb_recording.wav"
    }

    enum NotificationName {
        static let start = "com.fonos.ios.kb.start"
        static let stop = "com.fonos.ios.kb.stop"
        static let cancel = "com.fonos.ios.kb.cancel"
        static let partial = "com.fonos.ios.kb.partial"
        static let result = "com.fonos.ios.kb.result"
    }

    enum Delivery: String, Equatable, Sendable {
        case insert
        case insertAndPressEnter = "insert_and_press_enter"
        case copyOnly = "copy_only"
    }

    enum ReadinessStatus: String, Equatable, Sendable {
        case inactive
        case ready
        case paused
        /// The ready window expired while an accepted utterance was still
        /// recording or processing. New utterances must not start.
        case finishing
        case expired
    }

    struct OutputDescriptor: Equatable, Sendable {
        let typeTag: String
        let pressEnter: Bool

        init(typeTag: String, pressEnter: Bool = false) {
            self.typeTag = typeTag
            self.pressEnter = pressEnter
        }
    }

    struct WorkflowManifestEntry: Codable, Equatable, Sendable {
        let id: String
        let name: String
        let icon: String
    }

    enum ConsumerResult: Equatable, Sendable {
        case insert(text: String, pressEnter: Bool)
        case copied(text: String)
        case error(message: String)
    }

    /// Old producers did not write delivery metadata; preserve their insertion
    /// behavior during rolling upgrades.
    static func resolvedDelivery(_ rawValue: String?) -> Delivery {
        rawValue.flatMap(Delivery.init(rawValue:)) ?? .insert
    }

    /// Reduce the frozen workflow outputs to the one action owned by the
    /// keyboard surface. Clipboard delivery already happens in the producer;
    /// insert/return are returned to the extension for explicit cursor input.
    static func resolvedDelivery(outputs: [OutputDescriptor]) -> Delivery {
        let insertionOutputs = outputs.filter {
            $0.typeTag == "insert" || $0.typeTag == "return_to_caller"
        }
        guard !insertionOutputs.isEmpty else { return .copyOnly }
        return insertionOutputs.contains(where: {
            $0.typeTag == "insert" && $0.pressEnter
        }) ? .insertAndPressEnter : .insert
    }

    static func callbackStatus(text: String, delivery: Delivery) -> String {
        switch delivery {
        case .insert: "done:\(text)"
        case .insertAndPressEnter: "done_enter:\(text)"
        case .copyOnly: "copied:\(text)"
        }
    }

    static func consumerResult(from status: String) -> ConsumerResult? {
        if status.hasPrefix("done_enter:") {
            return .insert(text: String(status.dropFirst("done_enter:".count)), pressEnter: true)
        }
        if status.hasPrefix("done:") {
            return .insert(text: String(status.dropFirst("done:".count)), pressEnter: false)
        }
        if status.hasPrefix("copied:") {
            return .copied(text: String(status.dropFirst("copied:".count)))
        }
        if status.hasPrefix("error:") {
            return .error(message: String(status.dropFirst("error:".count)))
        }
        return nil
    }

    static let processingTimeout: TimeInterval = 60
    static let defaultReadySessionDuration: TimeInterval = 15 * 60
    static let minimumReadySessionDuration: TimeInterval = 60
    static let maximumReadySessionDuration: TimeInterval = 30 * 60

    static func clampedReadySessionDuration(_ duration: TimeInterval) -> TimeInterval {
        min(max(duration, minimumReadySessionDuration), maximumReadySessionDuration)
    }

    static func isFreshHeartbeat(_ heartbeat: Double, now: Double, maxAge: TimeInterval = 3) -> Bool {
        heartbeat > 0 && now - heartbeat <= maxAge
    }

    static func hasLiveApp(heartbeat: Double, appInstanceID: String?, now: Double,
                           maxAge: TimeInterval = 3) -> Bool {
        guard appInstanceID?.isEmpty == false else { return false }
        return isFreshHeartbeat(heartbeat, now: now, maxAge: maxAge)
    }

    static func isReadySession(
        status: ReadinessStatus?,
        sessionID: String?,
        expiresAt: Double,
        now: Double
    ) -> Bool {
        status == .ready
            && sessionID?.isEmpty == false
            && expiresAt > now
    }

    static func hasReadyApp(
        heartbeat: Double,
        appInstanceID: String?,
        readinessStatus: ReadinessStatus?,
        readySessionID: String?,
        readyExpiresAt: Double,
        now: Double,
        maxHeartbeatAge: TimeInterval = 3
    ) -> Bool {
        hasLiveApp(
            heartbeat: heartbeat,
            appInstanceID: appInstanceID,
            now: now,
            maxAge: maxHeartbeatAge
        ) && isReadySession(
            status: readinessStatus,
            sessionID: readySessionID,
            expiresAt: readyExpiresAt,
            now: now
        )
    }

    static func isSameAppInstance(_ expected: String?, current: String?) -> Bool {
        guard let expected, !expected.isEmpty,
              let current, !current.isEmpty else {
            return false
        }
        return expected == current
    }
}

struct KeyboardIPCSessionTracker {
    private(set) var currentSessionID: String?
    private(set) var resultHandled = false

    var hasActiveSession: Bool {
        currentSessionID?.isEmpty == false
    }

    /// Cleanup should notify the producer only while a result is outstanding.
    /// A handled result keeps its id briefly for deduplication but must not
    /// generate a late cancel notification.
    var cancellationSessionID: String? {
        guard !resultHandled else { return nil }
        return currentSessionID?.isEmpty == false ? currentSessionID : nil
    }

    mutating func begin(sessionID: String) {
        currentSessionID = sessionID
        resultHandled = false
    }

    mutating func clear() {
        currentSessionID = nil
        resultHandled = false
    }

    func accepts(resultSessionID: String?) -> Bool {
        guard !resultHandled,
              let currentSessionID,
              let resultSessionID,
              !resultSessionID.isEmpty else {
            return false
        }
        return resultSessionID == currentSessionID
    }

    mutating func markResultHandled() {
        resultHandled = true
    }
}

struct KeyboardIPCProducerSessionState {
    private(set) var activeSessionID: String?

    mutating func begin(sessionID: String?) {
        activeSessionID = sessionID
    }

    func captureForResult() -> String? {
        activeSessionID
    }

    mutating func clearIfActive(sessionID: String?) {
        guard let sessionID, activeSessionID == sessionID else { return }
        activeSessionID = nil
    }

    /// Consume a cancellation only when it names the producer's active
    /// session. A stale extension timeout can therefore never cancel a newer
    /// recording or processing task.
    @discardableResult
    mutating func cancelIfActive(sessionID: String?) -> Bool {
        guard let sessionID, !sessionID.isEmpty,
              activeSessionID == sessionID else { return false }
        activeSessionID = nil
        return true
    }
}
