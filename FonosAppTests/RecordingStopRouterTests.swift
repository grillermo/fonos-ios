import Foundation
import Testing
@testable import FonosApp

@MainActor
@Suite(.serialized)
struct RecordingStopRouterTests {
    @Test("stopAll runs each registered stop once and clears them")
    func stopAllRunsEachStopOnce() {
        let router = RecordingStopRouter()
        let dictation = NSObject(), note = NSObject()
        var stopped: [String] = []
        router.register(dictation) { stopped.append("dictation") }
        router.register(note) { stopped.append("note") }

        router.stopAll()
        router.stopAll()

        #expect(stopped.sorted() == ["dictation", "note"])
        #expect(!router.hasActiveRecording)
    }

    @Test("an unregistered owner is not stopped")
    func unregisteredOwnerIsNotStopped() {
        let router = RecordingStopRouter()
        let owner = NSObject()
        var stopped = false
        router.register(owner) { stopped = true }

        router.unregister(owner)
        router.stopAll()

        #expect(!stopped)
    }

    @Test("a return key edit adds one newline at the cursor", arguments: [
        ("hello", "hello\n"),
        (nil, "\n"),
        ("", "\n"),
        ("line\n", "line\n\n"),
        ("the start scrolled out of the window", "scrolled out of the window\n"),
    ] as [(String?, String?)])
    func returnKeyEdit(before: String?, after: String?) {
        #expect(KeyboardIPC.isReturnKeyEdit(before: before, after: after))
    }

    @Test("other edits are not a return key edit", arguments: [
        ("hello", "hello!"),
        ("hello", nil),
        ("hello", ""),
        ("first\nsecond", "other\n"),
        ("hello\n", "hello\nx"),
    ] as [(String?, String?)])
    func otherEdit(before: String?, after: String?) {
        #expect(!KeyboardIPC.isReturnKeyEdit(before: before, after: after))
    }

    @Test("dictation routes Return only while capturing")
    func dictationRoutesOnlyWhileCapturing() {
        let viewModel = DictationViewModel()
        defer { viewModel.recordingState = .idle }

        viewModel.recordingState = .recording
        #expect(RecordingStopRouter.shared.isRegistered(viewModel))

        viewModel.recordingState = .processing
        #expect(!RecordingStopRouter.shared.isRegistered(viewModel))
    }
}
