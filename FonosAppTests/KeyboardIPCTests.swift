import Testing
@testable import FonosApp

struct KeyboardIPCTests {

    @Test("fresh heartbeat is accepted")
    func freshHeartbeatIsAccepted() {
        #expect(KeyboardIPC.isFreshHeartbeat(100, now: 120))
    }

    @Test("stale or missing heartbeat is rejected")
    func staleHeartbeatIsRejected() {
        #expect(!KeyboardIPC.isFreshHeartbeat(0, now: 120))
        #expect(!KeyboardIPC.isFreshHeartbeat(80, now: 120))
    }

    @Test("session tracker accepts only the active keyboard result")
    func sessionTrackerIgnoresStaleResults() {
        var tracker = KeyboardIPCSessionTracker()

        tracker.begin(sessionID: "current")

        #expect(!tracker.accepts(resultSessionID: nil))
        #expect(!tracker.accepts(resultSessionID: "old"))
        #expect(tracker.accepts(resultSessionID: "current"))
    }

    @Test("session tracker handles each result once")
    func sessionTrackerHandlesResultOnce() {
        var tracker = KeyboardIPCSessionTracker()

        tracker.begin(sessionID: "current")
        #expect(tracker.accepts(resultSessionID: "current"))

        tracker.markResultHandled()
        #expect(!tracker.accepts(resultSessionID: "current"))
    }

    @Test("starting a new session clears stale handled state")
    func startingNewSessionClearsHandledState() {
        var tracker = KeyboardIPCSessionTracker()

        tracker.begin(sessionID: "first")
        tracker.markResultHandled()
        tracker.begin(sessionID: "second")

        #expect(!tracker.accepts(resultSessionID: "first"))
        #expect(tracker.accepts(resultSessionID: "second"))
    }
}
