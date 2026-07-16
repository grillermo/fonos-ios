// INV-11: Offline graceful degradation — Apple STT works on-device, cloud STT returns
// clear error, LLM skipped with message, no crash.
//
// Verifier: auto
// Level: unit (network layer mocked to simulate connectivity loss)
// Run: xcodebuild test -scheme FonosApp -only-testing:FonosAppTests/INV11OfflineTests

import Testing
import Foundation
import Speech
@testable import FonosApp

// MARK: - Mock URLProtocol that always fails with no-connection error

private final class OfflineMockURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
    }

    override func stopLoading() {}
}

private func makeOfflineSession() -> URLSession {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [OfflineMockURLProtocol.self]
    return URLSession(configuration: config)
}

// MARK: - Mock on-device speech recognizer (no network needed)

private final class OnDeviceMockRecognizer: SpeechRecognizerProtocol, @unchecked Sendable {
    private let transcript = "hello from device"

    func requestAuthorization(_ handler: @escaping (SFSpeechRecognizerAuthorizationStatus) -> Void) {
        handler(.authorized)
    }

    func recognize(request: SFSpeechAudioBufferRecognitionRequest,
                   resultHandler: @escaping (SpeechRecognitionOutput?, Error?) -> Void) -> SFSpeechRecognitionTask {
        // Simulate on-device recognition succeeding without any network.
        resultHandler(
            SpeechRecognitionOutput(transcript: transcript, isFinal: true),
            nil
        )
        return SFSpeechRecognitionTask()
    }
}

private func dummyAudioData() -> Data { Data(count: 44) }

@MainActor
private func waitForOfflineDictation(
    _ viewModel: DictationViewModel,
    terminal: (DictationViewModel.RecordingState) -> Bool
) async {
    for _ in 0..<2_000 {
        if terminal(viewModel.recordingState) { return }
        await Task.yield()
    }
    Issue.record("Timed out waiting for dictation")
}

// MARK: - Tests

struct INV11OfflineTests {

    // MARK: - Apple STT (on-device)

    @Test("AppleSTT succeeds without network using on-device recognizer")
    func appleSTTSucceedsOffline() async throws {
        let mock = OnDeviceMockRecognizer()
        let stt = AppleSTT(recognizer: mock)
        // Should NOT throw — on-device recognition requires no network
        let result = try await stt.transcribe(buffer: dummyAudioData(), language: "en-US")
        #expect(!result.isEmpty)
    }

    // MARK: - WhisperSTT (cloud — must fail gracefully)

    @Test("WhisperSTT with no network throws STTError.networkUnavailable (not crash)")
    func whisperSTTOfflineThrowsConnectivityError() async throws {
        let stt = authorizedWhisperSTT(session: makeOfflineSession(), apiKey: "sk-test")
        await #expect(throws: STTError.networkUnavailable) {
            _ = try await stt.transcribe(audioData: dummyAudioData(), language: "en")
        }
    }

    @Test("WhisperSTT offline error message is user-friendly (not a raw system error)")
    func whisperSTTOfflineErrorDescriptive() async throws {
        let stt = authorizedWhisperSTT(session: makeOfflineSession(), apiKey: "sk-test")
        do {
            _ = try await stt.transcribe(audioData: dummyAudioData(), language: "en")
            Issue.record("Expected STTError to be thrown")
        } catch let error as STTError {
            // The error description must be human-readable, not "The network connection was lost."
            let description = error.localizedDescription
            #expect(!description.isEmpty)
            // Must not just be a raw URLError string
            #expect(description.count > 10)
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }
    }

    // MARK: - FonosSTT (cloud — must fail gracefully)

    @Test("FonosSTT with no network throws STTError.networkUnavailable (not crash)")
    func fonosSTTOfflineThrowsConnectivityError() async throws {
        let stt = authorizedFonosSTT(session: makeOfflineSession(),
                           serverURL: URL(string: "http://192.168.1.100:8000")!)
        await #expect(throws: STTError.networkUnavailable) {
            _ = try await stt.transcribe(audioData: dummyAudioData(), language: "en")
        }
    }

    // MARK: - LLMService (cloud — must fail gracefully with user-friendly message)

    @Test("LLMService with no network throws LLMError.networkUnavailable")
    func llmServiceOfflineThrowsConnectivityError() async throws {
        let service = authorizedLLMService(session: makeOfflineSession(), apiKey: "sk-test")
        await #expect(throws: LLMError.networkUnavailable) {
            _ = try await service.process(
                text: "some text",
                configuration: workflowLLMConfiguration(for: .polish)
            )
        }
    }

    @Test("LLMService offline error has user-friendly localizedDescription")
    func llmOfflineErrorDescriptive() async throws {
        let service = authorizedLLMService(session: makeOfflineSession(), apiKey: "sk-test")
        do {
            _ = try await service.process(
                text: "hello",
                configuration: workflowLLMConfiguration(for: .polish)
            )
            Issue.record("Expected LLMError to be thrown")
        } catch let error as LLMError {
            #expect(!error.localizedDescription.isEmpty)
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }
    }

    // MARK: - DictationSession orchestration

    @Test("DictationSession with STT offline error surfaces error to caller (does not crash)")
    @MainActor
    func dictationSessionSTTOfflineError() async throws {
        let stt = authorizedWhisperSTT(session: makeOfflineSession(), apiKey: "sk-test")
        let vm = DictationViewModel(sttProvider: stt)
        vm.finishRecording(wavData: dummyAudioData())
        await waitForOfflineDictation(vm) {
            if case .error = $0 { return true }
            return false
        }
        if case .error(let message) = vm.recordingState {
            #expect(message == STTError.networkUnavailable.localizedDescription)
        } else {
            Issue.record("Expected the canonical workflow to surface an STT error")
        }
    }

    @Test("DictationViewModel falls back to raw transcript when LLM is offline")
    @MainActor
    func dictationViewModelFallsBackToRawOnLLMFailure() async throws {
        // STT succeeds; LLM fails; result should be the raw STT transcript
        let mockRecognizer = OnDeviceMockRecognizer()
        let stt = AppleSTT(recognizer: mockRecognizer)
        let llm = authorizedLLMService(session: makeOfflineSession(), apiKey: "sk-test")
        let vm = DictationViewModel(sttProvider: stt, llmProvider: llm)

        vm.selectMode(id: "polish")
        vm.finishRecording(wavData: dummyAudioData())
        await waitForOfflineDictation(vm) {
            if case .result = $0 { return true }
            return false
        }
        // use_input fallback returns the corrected STT text without crashing.
        if case .result(let transcript, let processed) = vm.recordingState {
            #expect(!transcript.isEmpty)
            #expect(processed == nil)
            #expect(vm.workflowPresentation.phase == .degraded)
        } else {
            Issue.record("Expected raw fallback result")
        }
    }
}
