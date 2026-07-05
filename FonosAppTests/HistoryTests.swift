// P0-1 / P0-3 (docs/ROADMAP.md): the dictation pipeline must persist a
// DictationSession on completion (History tab is empty otherwise) and must
// measure STT/LLM latency (badges never show otherwise).
//
// Run: xcodebuild test -scheme FonosApp -only-testing:FonosAppTests/DictationPersistenceTests

import Testing
import SwiftData
import Foundation
@testable import FonosApp

// MARK: - Mocks

/// STT that returns a fixed transcript after a small delay (so latency is measurable).
private final class FixedSTT: STTProvider, @unchecked Sendable {
    let transcript: String
    init(transcript: String) { self.transcript = transcript }
    func transcribe(audioData: Data, language: String?) async throws -> String {
        try await Task.sleep(nanoseconds: 20_000_000)
        return transcript
    }
}

/// URLProtocol returning a canned OpenAI chat completion (INV-05 pattern).
private final class SuccessLLMURLProtocol: URLProtocol {
    nonisolated(unsafe) static var content = "polished text"

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        let body = """
        {"id":"chatcmpl-test","object":"chat.completion",
         "choices":[{"index":0,"message":{"role":"assistant","content":"\(Self.content)"},"finish_reason":"stop"}]}
        """
        let resp = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body.data(using: .utf8)!)
        client?.urlProtocolDidFinishLoading(self)
    }
}

private func makeSuccessLLM() -> LLMService {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [SuccessLLMURLProtocol.self]
    return LLMService(session: URLSession(configuration: config), apiKey: "sk-test")
}

@MainActor
private func makeContainer() throws -> ModelContainer {
    try ModelContainer(
        for: Schema([DictationSession.self]),
        configurations: ModelConfiguration(isStoredInMemoryOnly: true)
    )
}

private func dummyWAV() -> Data { Data(count: 44) }

/// Polls until the view model reaches `.result`, recording a failure on timeout/error.
@MainActor
private func waitForResult(_ vm: DictationViewModel, timeout: TimeInterval = 5) async throws {
    let start = Date()
    while Date().timeIntervalSince(start) < timeout {
        if case .result = vm.recordingState { return }
        if case .error(let message) = vm.recordingState {
            Issue.record("Pipeline ended in error state: \(message)")
            return
        }
        try await Task.sleep(nanoseconds: 30_000_000)
    }
    Issue.record("Timed out waiting for .result state")
}

// MARK: - Tests

@Suite(.serialized)
struct DictationPersistenceTests {

    // P0-1: completing a dictation must insert a DictationSession.

    @Test("Raw-mode dictation persists a session with input == output")
    @MainActor
    func rawModePersistsSession() async throws {
        let container = try makeContainer()
        let vm = DictationViewModel(sttProvider: FixedSTT(transcript: "hello world"))
        vm.modelContext = container.mainContext

        vm.finishRecording(wavData: dummyWAV())
        try await waitForResult(vm)

        let sessions = try container.mainContext.fetch(FetchDescriptor<DictationSession>())
        #expect(sessions.count == 1)
        #expect(sessions.first?.inputText == "hello world")
        #expect(sessions.first?.outputText == "hello world")
        #expect(sessions.first?.mode == "raw")
    }

    @Test("LLM-mode dictation persists raw transcript as input and processed text as output")
    @MainActor
    func llmModePersistsRawAndProcessed() async throws {
        SuccessLLMURLProtocol.content = "polished text"
        let container = try makeContainer()
        let vm = DictationViewModel(
            sttProvider: FixedSTT(transcript: "um yeah raw text"),
            llmService: makeSuccessLLM()
        )
        vm.config.activeModeID = "polish"
        vm.modelContext = container.mainContext

        vm.finishRecording(wavData: dummyWAV())
        try await waitForResult(vm)

        let sessions = try container.mainContext.fetch(FetchDescriptor<DictationSession>())
        #expect(sessions.count == 1)
        #expect(sessions.first?.inputText == "um yeah raw text")
        #expect(sessions.first?.outputText == "polished text")
        #expect(sessions.first?.mode == "polish")
        #expect(sessions.first.map { $0.latencyMs > 0 } == true)
    }

    @Test("Dictation without a modelContext completes without persisting or crashing")
    @MainActor
    func noContextDoesNotCrash() async throws {
        let vm = DictationViewModel(sttProvider: FixedSTT(transcript: "hello"))

        vm.finishRecording(wavData: dummyWAV())
        try await waitForResult(vm)

        if case .result(let transcript, _) = vm.recordingState {
            #expect(transcript == "hello")
        }
    }

    // P0-3: latency must be measured around the STT and LLM calls.

    @Test("processAudio measures STT latency")
    func processAudioMeasuresSTTLatency() async throws {
        let vm = DictationViewModel(sttProvider: FixedSTT(transcript: "hi"))
        _ = try await vm.processAudio(dummyWAV(), language: nil, mode: .raw)
        await MainActor.run {
            #expect(vm.sttLatency > 0)
        }
    }

    @Test("processAudio measures LLM latency when a mode requires the LLM")
    func processAudioMeasuresLLMLatency() async throws {
        SuccessLLMURLProtocol.content = "done"
        let vm = DictationViewModel(sttProvider: FixedSTT(transcript: "hi"),
                                    llmService: makeSuccessLLM())
        _ = try await vm.processAudio(dummyWAV(), language: nil, mode: .polish)
        await MainActor.run {
            #expect(vm.sttLatency > 0)
            #expect(vm.llmLatency > 0)
        }
    }

    // ProcessResult must carry the raw transcript so History and the result
    // card can show the original alongside the processed text.

    @Test("ProcessResult keeps the raw transcript when LLM processing succeeds")
    func processResultCarriesRawTranscript() async throws {
        SuccessLLMURLProtocol.content = "polished output"
        let vm = DictationViewModel(sttProvider: FixedSTT(transcript: "raw input"),
                                    llmService: makeSuccessLLM())
        let result = try await vm.processAudio(dummyWAV(), language: nil, mode: .polish)
        #expect(result.rawTranscript == "raw input")
        #expect(result.text == "polished output")
    }
}
