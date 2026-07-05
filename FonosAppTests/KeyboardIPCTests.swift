import Testing
@testable import FonosApp

struct KeyboardIPCTests {

    @Test("fresh heartbeat is accepted")
    func freshHeartbeatIsAccepted() {
        #expect(KeyboardIPC.isFreshHeartbeat(119, now: 120))
    }

    @Test("stale or missing heartbeat is rejected")
    func staleHeartbeatIsRejected() {
        #expect(!KeyboardIPC.isFreshHeartbeat(0, now: 120))
        #expect(!KeyboardIPC.isFreshHeartbeat(80, now: 120))
    }

    @Test("live app requires fresh heartbeat and app instance")
    func liveAppRequiresHeartbeatAndInstance() {
        #expect(KeyboardIPC.hasLiveApp(heartbeat: 119, appInstanceID: "app", now: 120))
        #expect(!KeyboardIPC.hasLiveApp(heartbeat: 119, appInstanceID: "", now: 120))
        #expect(!KeyboardIPC.hasLiveApp(heartbeat: 110, appInstanceID: "app", now: 120))
    }

    @Test("app instance identity rejects restarts during an active session")
    func appInstanceIdentityRejectsRestarts() {
        #expect(KeyboardIPC.isSameAppInstance("first", current: "first"))
        #expect(!KeyboardIPC.isSameAppInstance("first", current: "second"))
        #expect(!KeyboardIPC.isSameAppInstance(nil, current: "second"))
        #expect(!KeyboardIPC.isSameAppInstance("first", current: nil))
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

    @Test("producer result session is captured before later sessions start")
    func producerResultSessionIsStableAcrossOverlappingTasks() {
        var state = KeyboardIPCProducerSessionState()

        state.begin(sessionID: "first")
        let firstTaskSession = state.captureForResult()

        state.begin(sessionID: "second")
        state.clearIfActive(sessionID: firstTaskSession)

        #expect(firstTaskSession == "first")
        #expect(state.activeSessionID == "second")
    }

    @Test("producer clears only the matching active session")
    func producerClearsOnlyMatchingSession() {
        var state = KeyboardIPCProducerSessionState()

        state.begin(sessionID: "first")
        state.clearIfActive(sessionID: "first")

        #expect(state.activeSessionID == nil)
    }
}
