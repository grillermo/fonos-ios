import Foundation
import Speech
import Testing
@testable import FonosApp

private enum SpeechFlowTestFailure: Error, Equatable {
    case stt
    case llm
}

private struct CapturedSTTCall: Equatable, Sendable {
    let language: String?
    let vocabulary: [String]
    let promptHint: String
}

private actor SpeechFlowSTTDouble: STTProvider {
    enum Behavior: Sendable {
        case succeed(String)
        case fail
    }

    private let behavior: Behavior
    private(set) var calls: [CapturedSTTCall] = []

    init(_ behavior: Behavior) {
        self.behavior = behavior
    }

    func transcribe(audioData: Data, language: String?) async throws -> String {
        try result()
    }

    func transcribe(
        audioData: Data,
        language: String?,
        vocabulary: [String],
        promptHint: String
    ) async throws -> String {
        calls.append(
            CapturedSTTCall(
                language: language,
                vocabulary: vocabulary,
                promptHint: promptHint
            )
        )
        return try result()
    }

    private func result() throws -> String {
        switch behavior {
        case .succeed(let text): return text
        case .fail: throw SpeechFlowTestFailure.stt
        }
    }
}

private struct CapturedLLMCall: Equatable, Sendable {
    let text: String
    let mode: Mode
    let glossary: String?
}

private actor SpeechFlowLLMDouble: SpeechFlowLLMProvider {
    enum Behavior: Sendable {
        case succeed(String)
        case fail
        case cancel
        case block
    }

    private let behavior: Behavior
    private(set) var calls: [CapturedLLMCall] = []

    init(_ behavior: Behavior) {
        self.behavior = behavior
    }

    func process(text: String, mode: Mode, glossary: String?) async throws -> String {
        calls.append(CapturedLLMCall(text: text, mode: mode, glossary: glossary))
        switch behavior {
        case .succeed(let output):
            return output
        case .fail:
            throw SpeechFlowTestFailure.llm
        case .cancel:
            throw CancellationError()
        case .block:
            try await Task.sleep(nanoseconds: 30_000_000_000)
            return "unexpected"
        }
    }
}

private actor SpeechFlowEventLog {
    private(set) var events: [SpeechFlowEvent] = []

    func append(_ event: SpeechFlowEvent) {
        events.append(event)
    }
}

private func makeSpeechFlow(
    id: String = "test-flow",
    stt: any STTProvider,
    llm: (any SpeechFlowLLMProvider)? = nil,
    failurePolicy: SpeechFlowLLMFailurePolicy = .useInput,
    books: [VocabBook] = [],
    language: String? = "en-US",
    promptHint: String = "Meeting vocabulary"
) -> ResolvedSpeechFlow {
    let postprocess: ResolvedSpeechFlow.Postprocess
    if let llm {
        postprocess = .llm(
            .init(provider: llm, mode: .polish, failurePolicy: failurePolicy)
        )
    } else {
        postprocess = .none(.notRequested)
    }

    return ResolvedSpeechFlow(
        flowID: id,
        stt: .init(provider: stt, language: language, promptHint: promptHint),
        vocab: SpeechFlowVocabSnapshot(effectiveBooks: books),
        postprocess: postprocess
    )
}

private func isSuccessfulTerminal(_ event: SpeechFlowEvent?) -> Bool {
    guard case .runSucceeded = event else { return false }
    return true
}

private func isFailedTerminal(_ event: SpeechFlowEvent?) -> Bool {
    guard case .runFailed = event else { return false }
    return true
}

private func isCancelledTerminal(_ event: SpeechFlowEvent?) -> Bool {
    guard case .runCancelled = event else { return false }
    return true
}

struct SpeechFlowRunnerTests {
    @Test("Raw Flow preserves provider/corrected/final text and forwards frozen STT config")
    func rawFlowContract() async throws {
        let secretTranscript = "We deploy cube net ease with my sequel"
        let stt = SpeechFlowSTTDouble(.succeed(secretTranscript))
        let books = [
            VocabBook(
                id: "tech",
                name: "Tech",
                terms: ["Kubernetes", "MySQL"],
                rules: [
                    VocabRule(from: "cube net ease", to: "Kubernetes"),
                    VocabRule(from: "my sequel", to: "MySQL")
                ]
            )
        ]
        let flow = makeSpeechFlow(stt: stt, books: books)

        let result = try await SpeechFlowRunner().run(
            SpeechFlowInput(wavData: Data(count: 44)),
            using: flow
        )

        #expect(result.providerTranscript == secretTranscript)
        #expect(result.correctedTranscript == "We deploy Kubernetes with MySQL")
        #expect(result.finalText == result.correctedTranscript)
        #expect(result.llmOutcome == .skipped(.notRequested))
        #expect(result.degradation == nil)
        #expect(result.timings.llm == nil)
        #expect(isSuccessfulTerminal(result.events.last))

        let call = await stt.calls.first
        #expect(call == CapturedSTTCall(
            language: "en-US",
            vocabulary: ["Kubernetes", "MySQL"],
            promptHint: "Meeting vocabulary"
        ))

        // Trace events are structural and must never contain user text.
        #expect(!String(describing: result.events).contains(secretTranscript))
    }

    @Test("LLM receives corrected text and glossary, while result keeps all three text layers")
    func llmSuccessContract() async throws {
        let stt = SpeechFlowSTTDouble(.succeed("we use my sequel"))
        let llm = SpeechFlowLLMDouble(.succeed("We use MySQL."))
        let books = [
            VocabBook(
                id: "database",
                name: "Database",
                terms: ["MySQL"],
                rules: [VocabRule(from: "my sequel", to: "MySQL")]
            )
        ]

        let result = try await SpeechFlowRunner().run(
            SpeechFlowInput(wavData: Data(count: 44)),
            using: makeSpeechFlow(stt: stt, llm: llm, books: books)
        )

        #expect(result.providerTranscript == "we use my sequel")
        #expect(result.correctedTranscript == "we use MySQL")
        #expect(result.finalText == "We use MySQL.")
        #expect(result.llmOutcome == .succeeded)
        #expect(result.degradation == nil)
        #expect(result.timings.llm != nil)

        let call = await llm.calls.first
        #expect(call?.text == "we use MySQL")
        #expect(call?.mode == .polish)
        #expect(call?.glossary?.contains("Domain vocabulary: MySQL") == true)
    }

    @Test("LLM useInput policy produces a successful degraded result")
    func llmFallbackContract() async throws {
        let stt = SpeechFlowSTTDouble(.succeed("corrected input"))
        let llm = SpeechFlowLLMDouble(.fail)

        let result = try await SpeechFlowRunner().run(
            SpeechFlowInput(wavData: Data(count: 44)),
            using: makeSpeechFlow(stt: stt, llm: llm, failurePolicy: .useInput)
        )

        #expect(result.finalText == "corrected input")
        #expect(result.llmOutcome == .fellBackToInput)
        #expect(result.degradation == .llmFailedUsingInput)
        #expect(result.events.contains { event in
            guard case .stepFinished(_, .llm, .fallback, _) = event else { return false }
            return true
        })
        #expect(isSuccessfulTerminal(result.events.last))
    }

    @Test("LLM failRun policy preserves the provider error and emits one failed terminal")
    func llmHardFailureContract() async throws {
        let stt = SpeechFlowSTTDouble(.succeed("input"))
        let llm = SpeechFlowLLMDouble(.fail)
        let log = SpeechFlowEventLog()

        do {
            _ = try await SpeechFlowRunner().run(
                SpeechFlowInput(wavData: Data(count: 44)),
                using: makeSpeechFlow(stt: stt, llm: llm, failurePolicy: .failRun),
                onEvent: { event in await log.append(event) }
            )
            Issue.record("Expected LLM failure")
        } catch let error as SpeechFlowTestFailure {
            #expect(error == .llm)
        }

        let events = await log.events
        #expect(isFailedTerminal(events.last))
        #expect(events.filter { event in
            guard case .runFailed = event else { return false }
            return true
        }.count == 1)
    }

    @Test("STT failure is fatal and prevents the LLM step")
    func sttFailureContract() async throws {
        let stt = SpeechFlowSTTDouble(.fail)
        let llm = SpeechFlowLLMDouble(.succeed("unused"))
        let log = SpeechFlowEventLog()

        do {
            _ = try await SpeechFlowRunner().run(
                SpeechFlowInput(wavData: Data(count: 44)),
                using: makeSpeechFlow(stt: stt, llm: llm),
                onEvent: { event in await log.append(event) }
            )
            Issue.record("Expected STT failure")
        } catch let error as SpeechFlowTestFailure {
            #expect(error == .stt)
        }

        #expect(await llm.calls.isEmpty)
        #expect(isFailedTerminal(await log.events.last))
    }

    @Test("An empty provider transcript is normalized to noTranscript")
    func emptySTTTranscriptFails() async throws {
        let stt = SpeechFlowSTTDouble(.succeed(""))

        await #expect(throws: STTError.noTranscript) {
            _ = try await SpeechFlowRunner().run(
                SpeechFlowInput(wavData: Data(count: 44)),
                using: makeSpeechFlow(stt: stt)
            )
        }
    }

    @Test("Cancellation during LLM is never converted into fallback")
    func cancellationIsNotFallback() async throws {
        let stt = SpeechFlowSTTDouble(.succeed("input"))
        let llm = SpeechFlowLLMDouble(.block)
        let log = SpeechFlowEventLog()
        let flow = makeSpeechFlow(stt: stt, llm: llm, failurePolicy: .useInput)

        let task = Task {
            try await SpeechFlowRunner().run(
                SpeechFlowInput(wavData: Data(count: 44)),
                using: flow,
                onEvent: { event in await log.append(event) }
            )
        }

        for _ in 0..<200 where await llm.calls.isEmpty {
            await Task.yield()
        }
        #expect(!(await llm.calls.isEmpty))

        task.cancel()
        await #expect(throws: CancellationError.self) {
            _ = try await task.value
        }

        let events = await log.events
        #expect(isCancelledTerminal(events.last))
        #expect(!events.contains { event in
            guard case .stepFinished(_, .llm, .fallback, _) = event else { return false }
            return true
        })
    }

    @Test("Dictation adapter clears stale LLM latency on the next raw run")
    @MainActor
    func dictationLatencyDoesNotLeakAcrossRuns() async throws {
        let stt = SpeechFlowSTTDouble(.succeed("input"))
        let llm = SpeechFlowLLMDouble(.succeed("output"))
        let vm = DictationViewModel(sttProvider: stt, llmService: llm)

        _ = try await vm.processAudio(Data(count: 44), language: nil, mode: .polish)
        #expect(vm.llmLatency > 0)

        _ = try await vm.processAudio(Data(count: 44), language: nil, mode: .raw)
        #expect(vm.llmLatency == 0)
    }

    @Test("An LLM mode without a configured provider is an intentional skip, not fallback")
    @MainActor
    func missingLLMIsNotDegraded() async throws {
        let stt = SpeechFlowSTTDouble(.succeed("corrected input"))
        let vm = DictationViewModel(sttProvider: stt)

        let result = try await vm.processAudio(
            Data(count: 44),
            language: nil,
            mode: .polish
        )

        #expect(result.text == "corrected input")
        #expect(!result.isRawFallback)
        #expect(!result.didProcessWithLLM)
        #expect(vm.llmLatency == 0)
    }

    @Test("Dictation Flow uses the custom ModeConfig UUID as vocab and prompt scope")
    @MainActor
    func customModeKeepsItsScopeID() async throws {
        let customID = UUID().uuidString
        let customMode = Mode.custom(
            systemPrompt: "Polish this",
            userTemplate: "{text}",
            temperature: 0.2,
            maxTokens: 256
        )
        let modeConfig = ModeConfig(
            id: customID,
            mode: customMode,
            name: "My Mode",
            icon: "sparkles",
            description: "Test mode",
            sttModelID: nil,
            llmModelID: nil,
            sttPrompt: "Names from this project",
            sttTemperature: 0,
            outputLanguage: "auto",
            autoPaste: false,
            isBuiltIn: false
        )

        let suiteName = "speech-flow-scope-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let vocabStore = VocabStore(defaults: defaults)
        vocabStore.upsert(
            VocabBook(id: "scoped", name: "Scoped", terms: ["FonosFlow"])
        )
        vocabStore.setMounted(
            ["scoped"],
            forKey: VocabStore.modeMountKey(customID)
        )

        let stt = SpeechFlowSTTDouble(.succeed("hello"))
        let vm = DictationViewModel(sttProvider: stt)
        vm.config.modeConfigs.append(modeConfig)
        vm.vocabStore = vocabStore

        _ = try await vm.processAudio(
            Data(count: 44),
            language: nil,
            mode: customMode,
            scopeID: customID
        )

        let call = await stt.calls.first
        #expect(call?.vocabulary == ["FonosFlow"])
        #expect(call?.promptHint == "Names from this project")
    }
}

private final class HoldingSpeechRecognizer: SpeechRecognizerProtocol, @unchecked Sendable {
    var stubbedTranscript: String? { nil }

    private let lock = NSLock()
    private var started = false

    var hasStarted: Bool {
        lock.lock()
        defer { lock.unlock() }
        return started
    }

    func updateLocale(_ locale: Locale) {}

    func requestAuthorization(
        _ handler: @escaping (SFSpeechRecognizerAuthorizationStatus) -> Void
    ) {
        handler(.authorized)
    }

    func recognize(
        request: SFSpeechAudioBufferRecognitionRequest,
        resultHandler: @escaping (SFSpeechRecognitionResult?, (any Error)?) -> Void
    ) -> SFSpeechRecognitionTask {
        lock.lock()
        started = true
        lock.unlock()
        return NoopCancellableSpeechTask()
    }
}

private final class NoopCancellableSpeechTask: SFSpeechRecognitionTask, @unchecked Sendable {
    override func cancel() {}
}

struct AppleSTTCancellationTests {
    @Test("AppleSTT resumes promptly when its parent task is cancelled")
    func appleSTTPropagatesCancellation() async throws {
        let recognizer = HoldingSpeechRecognizer()
        let stt = AppleSTT(recognizer: recognizer)
        let task = Task {
            try await stt.transcribe(buffer: Data(count: 44), language: "en-US")
        }

        for _ in 0..<200 where !recognizer.hasStarted {
            await Task.yield()
        }
        #expect(recognizer.hasStarted)

        task.cancel()
        await #expect(throws: CancellationError.self) {
            _ = try await task.value
        }
    }
}
