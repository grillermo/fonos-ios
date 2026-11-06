// Temporary failures wait for the next auto-retry; permanent ones stop it.
//
// Run: xcodebuild test -scheme FonosApp -only-testing:FonosAppTests/PendingRecordingFailureTests

import Testing
import Foundation
@testable import FonosApp

private struct UnknownError: Error {}

struct PendingRecordingFailureTests {

    @Test("connection problems, overload and unknown errors are temporary", arguments: [
        URLError(.notConnectedToInternet) as any Error,
        STTError.timeout,
        STTError.networkUnavailable,
        STTError.recognizerError("Request failed"),
        STTError.http(status: 408, body: ""),
        STTError.http(status: 429, body: ""),
        STTError.http(status: 502, body: ""),
        STTError.http(status: 503, body: ""),
        UnknownError(),
    ])
    func temporary(_ error: any Error) {
        #expect(PendingRecordingFailure.classify(error) == .temporary)
    }

    @Test("failures a retry cannot fix are permanent", arguments: [
        STTError.http(status: 400, body: "") as any Error,
        STTError.http(status: 415, body: ""),
        STTError.badRequest,
        STTError.authenticationFailed,
        STTError.consentRequired("x"),
        STTError.insecureEndpoint,
        STTError.m4aUnsupported,
        STTError.profileUnavailable("x"),
        PendingRecordingError.recipeUnavailable,
        PendingRecordingError.notebookUnavailable,
    ])
    func permanent(_ error: any Error) {
        #expect(PendingRecordingFailure.classify(error) == .permanent)
    }

    @Test("a busy app or a cancelled run is not a failure", arguments: [
        PendingRecordingError.dictationBusy as any Error,
        PendingRecordingError.alreadyRetrying,
        CancellationError(),
    ])
    func busy(_ error: any Error) {
        #expect(PendingRecordingFailure.classify(error) == .busy)
    }

    @Test("a recording that no longer exists is gone")
    func gone() {
        #expect(PendingRecordingFailure.classify(PendingRecordingError.notFound) == .gone)
    }

    @Test("both routes failing is temporary if either side is")
    func failover() {
        let temporary = STTError.timeout
        let permanent = STTError.http(status: 415, body: "")
        #expect(PendingRecordingFailure.classify(
            EndpointFailoverError(primary: temporary, fallback: permanent)
        ) == .temporary)
        #expect(PendingRecordingFailure.classify(
            EndpointFailoverError(primary: permanent, fallback: temporary)
        ) == .temporary)
        #expect(PendingRecordingFailure.classify(
            EndpointFailoverError(primary: permanent, fallback: permanent)
        ) == .permanent)
    }
}

struct PendingRecordingTitleTests {
    private func recording(
        surface: PendingRecording.Surface,
        noteEntryID: UUID? = nil
    ) -> PendingRecording {
        PendingRecording(
            id: UUID(), surface: surface, workflowID: nil, notebookID: nil,
            createdAt: Date(), lastError: "e", attempts: 0, durationSeconds: 1,
            noteEntryID: noteEntryID
        )
    }

    @Test("titles say what each recording is")
    @MainActor
    func titles() {
        #expect(PendingRecordingsView.title(
            for: recording(surface: .dictate), recipeName: "Polish", notebookName: nil
        ) == "Polish")
        #expect(PendingRecordingsView.title(
            for: recording(surface: .dictate), recipeName: nil, notebookName: nil
        ) == "Dictation")
        #expect(PendingRecordingsView.title(
            for: recording(surface: .note), recipeName: nil, notebookName: "Work"
        ) == "Voice note · Work")
        #expect(PendingRecordingsView.title(
            for: recording(surface: .note, noteEntryID: UUID()), recipeName: nil, notebookName: "Ideas"
        ) == "Addition · Ideas")
        #expect(PendingRecordingsView.title(
            for: recording(surface: .note), recipeName: nil, notebookName: nil
        ) == "Voice note")
    }
}
