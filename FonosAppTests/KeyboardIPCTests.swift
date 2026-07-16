import AVFoundation
import Testing
@testable import FonosApp

struct KeyboardIPCTests {

    @Test("Keyboard Ready presentation distinguishes every runtime state")
    func readyPresentationStates() {
        let cases: [(KeyboardIPC.ReadinessStatus, String?, KeyboardReadyVisualState, String)] = [
            (.inactive, nil, .inactive, "mic.slash"),
            (.ready, nil, .ready, "mic.fill"),
            (.ready, " recording\n", .recording, "waveform"),
            (.paused, "recording", .paused, "pause.fill"),
            (.finishing, "recording", .finishing, "hourglass"),
            (.expired, nil, .expired, "clock.badge.exclamationmark"),
        ]

        for (readiness, operation, expectedState, expectedIcon) in cases {
            let presentation = KeyboardReadyPresentation(
                readinessStatus: readiness,
                operationStatus: operation
            )
            #expect(presentation.state == expectedState)
            #expect(presentation.iconName == expectedIcon)
        }
    }

    @Test("paused and finishing banners never claim the microphone is active")
    func inactiveMicrophoneCopyIsHonest() {
        for status in [KeyboardIPC.ReadinessStatus.paused, .finishing] {
            let presentation = KeyboardReadyPresentation(
                readinessStatus: status,
                operationStatus: "recording"
            )
            let detail = presentation.detail(remainingSeconds: 75)
            #expect(!presentation.usesActiveMicrophoneStyle)
            #expect(!detail.localizedCaseInsensitiveContains("Microphone active"))
        }

        let ready = KeyboardReadyPresentation(readinessStatus: .ready)
        let recording = KeyboardReadyPresentation(
            readinessStatus: .ready,
            operationStatus: "recording"
        )
        #expect(ready.usesActiveMicrophoneStyle)
        #expect(recording.usesActiveMicrophoneStyle)
        #expect(ready.detail(remainingSeconds: 75).contains("1:15"))
        #expect(recording.detail(remainingSeconds: 75).contains("1:15"))
    }

    @Test("delivery metadata defaults old producers to insertion")
    func deliveryMetadataCompatibility() {
        #expect(KeyboardIPC.resolvedDelivery(nil) == .insert)
        #expect(KeyboardIPC.resolvedDelivery("") == .insert)
        #expect(KeyboardIPC.resolvedDelivery("insert") == .insert)
        #expect(KeyboardIPC.resolvedDelivery("insert_and_press_enter") == .insertAndPressEnter)
        #expect(KeyboardIPC.resolvedDelivery("copy_only") == .copyOnly)
        #expect(KeyboardIPC.resolvedDelivery("future") == .insert)
    }

    @Test("workflow outputs preserve insert press-enter semantics")
    func workflowOutputDeliveryMetadata() {
        #expect(KeyboardIPC.resolvedDelivery(outputs: [
            .init(typeTag: "clipboard")
        ]) == .copyOnly)
        #expect(KeyboardIPC.resolvedDelivery(outputs: [
            .init(typeTag: "insert", pressEnter: false)
        ]) == .insert)
        #expect(KeyboardIPC.resolvedDelivery(outputs: [
            .init(typeTag: "clipboard"),
            .init(typeTag: "insert", pressEnter: true)
        ]) == .insertAndPressEnter)
        #expect(KeyboardIPC.resolvedDelivery(outputs: [
            .init(typeTag: "return_to_caller", pressEnter: true)
        ]) == .insert)
    }

    @Test("keyboard history preserves every workflow output")
    func keyboardHistoryPreservesMultiOutputDestinations() {
        #expect(KeyboardWorkflowHistory.destinationSummary(outputs: [
            .init(typeTag: "clipboard"),
            .init(typeTag: "insert"),
            .init(typeTag: "return_to_caller")
        ]) == "clipboard,keyboard")
        #expect(KeyboardWorkflowHistory.destinationSummary(outputs: [
            .init(typeTag: "insert"),
            .init(typeTag: "clipboard")
        ]) == "keyboard,clipboard")
    }

    @Test("only hardware route changes rebuild Keyboard Ready")
    func keyboardReadyRouteChangePolicy() {
        #expect(BackgroundRecordingService.routeChangeRequiresReadyEngineRebuild(
            .newDeviceAvailable
        ))
        #expect(BackgroundRecordingService.routeChangeRequiresReadyEngineRebuild(
            .oldDeviceUnavailable
        ))
        #expect(BackgroundRecordingService.routeChangeRequiresReadyEngineRebuild(
            .routeConfigurationChange
        ))
        #expect(!BackgroundRecordingService.routeChangeRequiresReadyEngineRebuild(
            .categoryChange
        ))
        #expect(!BackgroundRecordingService.routeChangeRequiresReadyEngineRebuild(
            .override
        ))
    }

    @Test("keyboard callback tells consumer to press enter after insertion")
    func pressEnterCallbackRoundTrip() {
        let status = KeyboardIPC.callbackStatus(
            text: "hello: world",
            delivery: .insertAndPressEnter
        )

        #expect(status == "done_enter:hello: world")
        #expect(KeyboardIPC.consumerResult(from: status) == .insert(
            text: "hello: world",
            pressEnter: true
        ))
        #expect(KeyboardIPC.consumerResult(from: "done:plain") == .insert(
            text: "plain",
            pressEnter: false
        ))
        #expect(KeyboardIPC.consumerResult(from: "copied:value") == .copied(text: "value"))
        #expect(KeyboardIPC.consumerResult(from: "error:failed") == .error(message: "failed"))
    }

    @Test("multi-processor keyboard timeout allows sixty seconds")
    func processingTimeoutAllowsRemoteFlow() {
        #expect(KeyboardIPC.processingTimeout == 60)
    }

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

    @Test("ready session requires status, identity, future expiry, and live app")
    func readySessionRequiresEveryLivenessSignal() {
        let valid = KeyboardIPC.hasReadyApp(
            heartbeat: 119,
            appInstanceID: "app",
            readinessStatus: .ready,
            readySessionID: "ready-session",
            readyExpiresAt: 180,
            now: 120
        )
        #expect(valid)

        #expect(!KeyboardIPC.hasReadyApp(
            heartbeat: 119,
            appInstanceID: "app",
            readinessStatus: .expired,
            readySessionID: "ready-session",
            readyExpiresAt: 180,
            now: 120
        ))
        #expect(!KeyboardIPC.hasReadyApp(
            heartbeat: 119,
            appInstanceID: "app",
            readinessStatus: .ready,
            readySessionID: "",
            readyExpiresAt: 180,
            now: 120
        ))
        #expect(!KeyboardIPC.hasReadyApp(
            heartbeat: 119,
            appInstanceID: "app",
            readinessStatus: .ready,
            readySessionID: "ready-session",
            readyExpiresAt: 120,
            now: 120
        ))
        #expect(!KeyboardIPC.hasReadyApp(
            heartbeat: 100,
            appInstanceID: "app",
            readinessStatus: .ready,
            readySessionID: "ready-session",
            readyExpiresAt: 180,
            now: 120
        ))
    }

    @Test("ready duration is bounded")
    func readyDurationIsBounded() {
        #expect(KeyboardIPC.defaultReadySessionDuration == 15 * 60)
        #expect(KeyboardIPC.clampedReadySessionDuration(1) == 60)
        #expect(KeyboardIPC.clampedReadySessionDuration(10 * 60) == 10 * 60)
        #expect(KeyboardIPC.clampedReadySessionDuration(60 * 60) == 30 * 60)
    }

    @Test("keyboard utterance automatically finalizes at five minutes")
    func keyboardUtteranceUsesFiveMinuteDeadline() {
        let start = Date(timeIntervalSince1970: 1_000)
        let deadline = KeyboardUtteranceDeadline.resolve(
            startedAt: start,
            readyExpiresAt: start.addingTimeInterval(15 * 60)
        )

        #expect(deadline.reason == .maximumDuration)
        #expect(deadline.date == start.addingTimeInterval(5 * 60))
    }

    @Test("Ready expiry finalizes an active utterance before its five-minute limit")
    func readyExpiryWinsUtteranceDeadline() {
        let start = Date(timeIntervalSince1970: 1_000)
        let expiry = start.addingTimeInterval(45)
        let deadline = KeyboardUtteranceDeadline.resolve(
            startedAt: start,
            readyExpiresAt: expiry
        )

        #expect(deadline.reason == .readySessionExpired)
        #expect(deadline.date == expiry)
    }

    @Test("Ready cleanup defers shared audio-session deactivation during foreground capture")
    func readyCleanupRespectsForegroundAudioOwnership() {
        #expect(KeyboardReadyAudioSessionPolicy.shouldDeferExpiry(
            foregroundCaptureDepth: 1
        ))
        #expect(!KeyboardReadyAudioSessionPolicy.shouldDeactivateSession(
            foregroundCaptureDepth: 1
        ))
        #expect(!KeyboardReadyAudioSessionPolicy.shouldDeferExpiry(
            foregroundCaptureDepth: 0
        ))
        #expect(KeyboardReadyAudioSessionPolicy.shouldDeactivateSession(
            foregroundCaptureDepth: 0
        ))
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
        #expect(tracker.cancellationSessionID == nil)
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

    @Test("producer cancellation cannot cancel a different session")
    func producerCancellationIsSessionScoped() {
        var state = KeyboardIPCProducerSessionState()
        state.begin(sessionID: "new-session")

        let staleCancelled = state.cancelIfActive(sessionID: "old-session")
        #expect(!staleCancelled)
        #expect(state.activeSessionID == "new-session")
        let activeCancelled = state.cancelIfActive(sessionID: "new-session")
        #expect(activeCancelled)
        #expect(state.activeSessionID == nil)
    }

    @Test("unhandled consumer session remains cancellable")
    func pendingConsumerSessionProvidesCancellationIdentity() {
        var tracker = KeyboardIPCSessionTracker()
        tracker.begin(sessionID: "pending")

        #expect(tracker.cancellationSessionID == "pending")
        tracker.markResultHandled()
        #expect(tracker.cancellationSessionID == nil)
    }
}
