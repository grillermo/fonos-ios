// P0-6 (docs/ROADMAP.md): RecordMode.hold is configurable in Settings but the
// dictation screen only implements tap. These tests drive the pure gesture
// decision logic; DictationView maps the actions onto start/stopRecording.
//
// Run: xcodebuild test -scheme FonosApp -only-testing:FonosAppTests/RecordGestureTests

import Testing
@testable import FonosApp

struct RecordGestureTests {

    // MARK: - Hold mode

    @Test("press down while idle starts recording")
    func pressDownFromIdleStarts() {
        let action = DictationViewModel.holdGestureAction(
            pressing: true, state: .idle, recordMode: .hold)
        #expect(action == .start)
    }

    @Test("press down from a previous result starts a new recording")
    func pressDownFromResultStarts() {
        let action = DictationViewModel.holdGestureAction(
            pressing: true, state: .result(transcript: "t", processed: nil), recordMode: .hold)
        #expect(action == .start)
    }

    @Test("press down from an error state starts a new recording")
    func pressDownFromErrorStarts() {
        let action = DictationViewModel.holdGestureAction(
            pressing: true, state: .error(message: "x"), recordMode: .hold)
        #expect(action == .start)
    }

    @Test("release while recording stops")
    func releaseWhileRecordingStops() {
        let action = DictationViewModel.holdGestureAction(
            pressing: false, state: .recording, recordMode: .hold)
        #expect(action == .stop)
    }

    @Test("release while audio setup is pending cancels the start")
    func releaseWhileStartingStops() {
        let action = DictationViewModel.holdGestureAction(
            pressing: false, state: .starting, recordMode: .hold)
        #expect(action == .stop)
    }

    @Test("release while processing does nothing")
    func releaseWhileProcessingIsNoop() {
        let action = DictationViewModel.holdGestureAction(
            pressing: false, state: .processing, recordMode: .hold)
        #expect(action == RecordGestureAction.none)
    }

    @Test("press down while already recording does nothing")
    func pressDownWhileRecordingIsNoop() {
        let action = DictationViewModel.holdGestureAction(
            pressing: true, state: .recording, recordMode: .hold)
        #expect(action == RecordGestureAction.none)
    }

    // MARK: - Tap mode: hold gesture must be inert

    @Test("hold gesture is inert in tap mode")
    func holdGestureInertInTapMode() {
        #expect(DictationViewModel.holdGestureAction(
            pressing: true, state: .idle, recordMode: .tap) == RecordGestureAction.none)
        #expect(DictationViewModel.holdGestureAction(
            pressing: false, state: .recording, recordMode: .tap) == RecordGestureAction.none)
    }
}
