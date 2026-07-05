import Foundation

enum KeyboardIPC {
    enum FileName {
        static let heartbeat = "kb_heartbeat"
        static let sessionID = "kb_session_id"
        static let startAckSessionID = "kb_start_ack_session_id"
        static let resultSessionID = "kb_result_session_id"
        static let appInstanceID = "kb_app_instance_id"
        static let status = "kb_status"
        static let partial = "kb_partial.txt"
        static let final = "kb_final.txt"
        static let error = "kb_error.txt"
        static let continuousAudio = "kb_continuous.wav"
        static let segmentAudio = "kb_recording.wav"
    }

    static func isFreshHeartbeat(_ heartbeat: Double, now: Double, maxAge: TimeInterval = 3) -> Bool {
        heartbeat > 0 && now - heartbeat <= maxAge
    }

    static func hasLiveApp(heartbeat: Double, appInstanceID: String?, now: Double,
                           maxAge: TimeInterval = 3) -> Bool {
        guard appInstanceID?.isEmpty == false else { return false }
        return isFreshHeartbeat(heartbeat, now: now, maxAge: maxAge)
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
}
