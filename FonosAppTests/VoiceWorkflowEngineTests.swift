import Foundation
import Testing
@testable import FonosApp

private enum VoiceWorkflowTestError: Error {
    case stt
    case llm
    case output
}

private struct WorkflowSTTCall: Equatable, Sendable {
    let language: String?
    let vocabulary: [String]
    let promptHint: String
    let temperature: Double
}

private actor WorkflowSTTDouble: STTProvider {
    enum Behavior: Sendable {
        case succeed(String)
        case fail
        case block
    }

    let behavior: Behavior
    private(set) var calls: [WorkflowSTTCall] = []

    init(_ behavior: Behavior) {
        self.behavior = behavior
    }

    func transcribe(audioData: Data, language: String?) async throws -> String {
        try await result()
    }

    func transcribe(
        audioData: Data,
        language: String?,
        vocabulary: [String],
        promptHint: String,
        temperature: Double
    ) async throws -> String {
        calls.append(.init(
            language: language,
            vocabulary: vocabulary,
            promptHint: promptHint,
            temperature: temperature
        ))
        return try await result()
    }

    private func result() async throws -> String {
        switch behavior {
        case .succeed(let text): return text
        case .fail: throw VoiceWorkflowTestError.stt
        case .block:
            try await Task.sleep(for: .seconds(30))
            return "unexpected"
        }
    }
}

private struct WorkflowLLMCall: Equatable, Sendable {
    let text: String
    let configuration: LLMRequestConfiguration
}

private actor WorkflowLLMDouble: VoiceWorkflowLLMProvider {
    enum Behavior: Sendable {
        case succeed(String)
        case fail
    }

    let behavior: Behavior
    private(set) var calls: [WorkflowLLMCall] = []

    init(_ behavior: Behavior) {
        self.behavior = behavior
    }

    func process(text: String, configuration: LLMRequestConfiguration) async throws -> String {
        calls.append(.init(text: text, configuration: configuration))
        switch behavior {
        case .succeed(let output): return output
        case .fail: throw VoiceWorkflowTestError.llm
        }
    }
}

private actor WorkflowOutputDouble: VoiceWorkflowOutput {
    let shouldFail: Bool
    private(set) var deliveries: [(String, VoiceWorkflowOutputContext)] = []

    init(shouldFail: Bool = false) {
        self.shouldFail = shouldFail
    }

    func deliver(text: String, context: VoiceWorkflowOutputContext) async throws {
        if shouldFail { throw VoiceWorkflowTestError.output }
        deliveries.append((text, context))
    }

    var texts: [String] { deliveries.map(\.0) }
}

private actor WorkflowEventLog {
    private(set) var events: [VoiceWorkflowTraceEvent] = []

    func append(_ event: VoiceWorkflowTraceEvent) {
        events.append(event)
    }
}

private actor WorkflowRecorderLog {
    private(set) var values: [VoiceWorkflowProcessedResult] = []

    func append(_ value: VoiceWorkflowProcessedResult) {
        values.append(value)
    }
}

private final class WorkflowLLMURLProtocol: URLProtocol {
    nonisolated(unsafe) static var responseContent = ""

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: nil
        )!
        let escaped = Self.responseContent
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
        let data = """
        {"choices":[{"message":{"content":"\(escaped)"}}]}
        """.data(using: .utf8)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private final class WorkflowResolutionCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String: Int] = [:]

    func increment(_ key: String) {
        lock.withLock { storage[key, default: 0] += 1 }
    }

    func value(_ key: String) -> Int {
        lock.withLock { storage[key, default: 0] }
    }
}

private func workflowWidget(
    id: String,
    role: WorkflowRole,
    typeTag: String,
    props: WorkflowJSONValue = .object([:])
) -> WorkflowWidget {
    WorkflowWidget(id: id, role: role, typeTag: typeTag, name: id, props: props)
}

private func voiceWorkflowFixture(
    failurePolicy: String = "use_input",
    sourceID: String = "src.mic",
    sourceType: String = "microphone",
    outputs: [String] = ["out.return"]
) -> (WorkflowCatalog, WorkflowDefinition) {
    let widgets: [WorkflowWidget] = [
        workflowWidget(id: sourceID, role: .source, typeTag: sourceType),
        workflowWidget(
            id: "stt.fixture",
            role: .processor,
            typeTag: "stt",
            props: .object([
                "model_profile": .string("stt-profile"),
                "stt_prompt": .string("Meeting words"),
                "temperature": .number(0.35),
                "language": .string("en-US"),
                "vocab_books": .array([.string("book.fixture")])
            ])
        ),
        workflowWidget(
            id: "llm.fixture",
            role: .processor,
            typeTag: "llm",
            props: .object([
                "system": .string("System"),
                "user_template": .string("Rewrite {text} for {target_lang}"),
                "model_profile": .string("llm-profile"),
                "temperature": .number(0.42),
                "max_tokens": .integer(777),
                "output_language": .string("French"),
                "vocab_books": .array([.string("book.fixture")]),
                "failure_policy": .string(failurePolicy)
            ])
        ),
        workflowWidget(id: "out.return", role: .output, typeTag: "return_to_caller"),
        workflowWidget(id: "out.clipboard", role: .output, typeTag: "clipboard")
    ]
    let definition = WorkflowDefinition(
        id: "wf.fixture",
        name: "Fixture",
        source: sourceID,
        processors: ["stt.fixture", "llm.fixture"],
        outputs: outputs
    )
    return (WorkflowCatalog(widgets: widgets, workflows: [definition]), definition)
}

private func compileFixture(
    failurePolicy: String = "use_input",
    sourceType: String = "microphone",
    stt: WorkflowSTTDouble,
    llm: WorkflowLLMDouble,
    output: WorkflowOutputDouble,
    counter: WorkflowResolutionCounter? = nil
) throws -> ResolvedVoiceWorkflow {
    let (catalog, definition) = voiceWorkflowFixture(
        failurePolicy: failurePolicy,
        sourceType: sourceType
    )
    let book = VocabBook(
        id: "book.fixture",
        name: "Fixture",
        terms: ["Fonos"],
        rules: [VocabRule(from: "phone us", to: "Fonos")]
    )
    return try VoiceWorkflowEngine().compile(
        definition: definition,
        catalog: catalog,
        resolver: VoiceWorkflowRuntimeResolver(
            resolveSTT: { widget in
                counter?.increment("stt:\(widget.id)")
                return ResolvedVoiceWorkflowSTT(provider: stt)
            },
            resolveLLM: { widget in
                counter?.increment("llm:\(widget.id)")
                return ResolvedVoiceWorkflowLLM(provider: llm, translateTarget: "German")
            },
            resolveVocabulary: { _, widget in
                counter?.increment("vocab:\(widget.id)")
                return VoiceWorkflowVocabulary(effectiveBooks: [book])
            },
            resolveOutput: { widget in
                counter?.increment("output:\(widget.id)")
                return output
            }
        )
    )
}

private func terminalCount(_ events: [VoiceWorkflowTraceEvent]) -> Int {
    events.count(where: \.isTerminal)
}

private func hasFinished(
    _ events: [VoiceWorkflowTraceEvent],
    widgetID: String,
    outcome: VoiceWorkflowStepOutcome
) -> Bool {
    events.contains { event in
        guard case .stepFinished(_, _, let step, let actual, _) = event else { return false }
        return step.widgetID == widgetID && actual == outcome
    }
}

struct VoiceWorkflowValidationTests {
    @Test("Validation derives the dynamic source, processors, and outputs in definition order")
    func validatesDynamicChain() throws {
        let (catalog, definition) = voiceWorkflowFixture(outputs: ["out.return", "out.clipboard"])
        let validation = try VoiceWorkflowEngine().validate(
            definition: definition,
            catalog: catalog
        )

        #expect(validation.sourceKind == .microphone)
        #expect(validation.finalKind == .text)
        #expect(validation.steps.map(\.widgetID) == [
            "src.mic", "stt.fixture", "llm.fixture", "out.return", "out.clipboard"
        ])
        #expect(validation.steps.map(\.index) == [0, 1, 2, 3, 4])
    }

    @Test("Validation rejects an unknown reference")
    func rejectsUnknownReference() {
        let (catalog, base) = voiceWorkflowFixture()
        var definition = base
        definition.processors = ["stt.missing"]

        #expect(throws: VoiceWorkflowCompileError.unknownWidget(
            workflowID: definition.id,
            widgetID: "stt.missing"
        )) {
            try VoiceWorkflowEngine().validate(definition: definition, catalog: catalog)
        }
    }

    @Test("Validation rejects role spoofing before provider resolution")
    func rejectsWrongRole() {
        let source = workflowWidget(id: "src.bad", role: .output, typeTag: "microphone")
        let definition = WorkflowDefinition(
            id: "wf.bad-role", name: "Bad", source: source.id, outputs: ["out.return"]
        )
        let output = workflowWidget(id: "out.return", role: .output, typeTag: "return_to_caller")
        let catalog = WorkflowCatalog(widgets: [source, output], workflows: [definition])

        #expect(throws: VoiceWorkflowCompileError.roleMismatch(
            widgetID: source.id,
            expected: .source,
            actual: .output
        )) {
            try VoiceWorkflowEngine().validate(definition: definition, catalog: catalog)
        }
    }

    @Test("Validation rejects a text processor before STT")
    func rejectsBrokenAudioTextChain() {
        let (catalog, base) = voiceWorkflowFixture()
        var definition = base
        definition.processors = ["llm.fixture"]

        #expect(throws: VoiceWorkflowCompileError.kindMismatch(
            widgetID: "llm.fixture",
            expected: .text,
            actual: .audio
        )) {
            try VoiceWorkflowEngine().validate(definition: definition, catalog: catalog)
        }
    }

    @Test("Validation requires an output")
    func rejectsNoOutputs() {
        let (catalog, base) = voiceWorkflowFixture()
        var definition = base
        definition.outputs = []

        #expect(throws: VoiceWorkflowCompileError.noOutputs(workflowID: definition.id)) {
            try VoiceWorkflowEngine().validate(definition: definition, catalog: catalog)
        }
    }

    @Test("Validation requires the processor chain to end in text")
    func rejectsAudioFinalKind() {
        let (catalog, base) = voiceWorkflowFixture()
        var definition = base
        definition.processors = []

        #expect(throws: VoiceWorkflowCompileError.finalKindMustBeText(actual: .audio)) {
            try VoiceWorkflowEngine().validate(definition: definition, catalog: catalog)
        }
    }

    @Test("Validation rejects unsupported desktop-only component types")
    func rejectsUnsupportedComponent() {
        let (baseCatalog, base) = voiceWorkflowFixture()
        var widgets = baseCatalog.widgets
        widgets[0].typeTag = "selection"
        let catalog = WorkflowCatalog(widgets: widgets, workflows: [base])

        #expect(throws: VoiceWorkflowCompileError.unsupportedWidget(
            widgetID: "src.mic",
            role: .source,
            typeTag: "selection"
        )) {
            try VoiceWorkflowEngine().validate(definition: base, catalog: catalog)
        }
    }

    @Test("Microphone capture defaults to hold and rejects unknown values")
    func validatesCaptureSemantics() throws {
        let (baseCatalog, definition) = voiceWorkflowFixture()
        var widgets = baseCatalog.widgets
        let sourceIndex = try #require(widgets.firstIndex { $0.id == "src.mic" })
        widgets[sourceIndex].props = .null
        _ = try VoiceWorkflowEngine().validate(
            definition: definition,
            catalog: WorkflowCatalog(widgets: widgets, workflows: [definition])
        )

        widgets[sourceIndex].props = .object(["capture": .string("press_once")])
        #expect(throws: VoiceWorkflowCompileError.invalidProperty(
            widgetID: "src.mic",
            key: "capture",
            reason: "expected hold or toggle"
        )) {
            try VoiceWorkflowEngine().validate(
                definition: definition,
                catalog: WorkflowCatalog(widgets: widgets, workflows: [definition])
            )
        }
    }

    @Test("Surface-only outputs require an explicit runtime capability")
    func rejectsSurfaceOutputDuringPortableValidation() throws {
        let (baseCatalog, baseDefinition) = voiceWorkflowFixture(outputs: ["out.ios"])
        var widgets = baseCatalog.widgets.filter { $0.id != "out.return" && $0.id != "out.clipboard" }
        widgets.append(workflowWidget(
            id: "out.ios",
            role: .output,
            typeTag: "ios_destination",
            props: .object(["destination_id": .string("messages")])
        ))
        let catalog = WorkflowCatalog(widgets: widgets, workflows: [baseDefinition])

        #expect(throws: VoiceWorkflowCompileError.unsupportedWidget(
            widgetID: "out.ios",
            role: .output,
            typeTag: "ios_destination"
        )) {
            try VoiceWorkflowEngine().validate(
                definition: baseDefinition,
                catalog: catalog
            )
        }
        _ = try VoiceWorkflowEngine().validate(
            definition: baseDefinition,
            catalog: catalog,
            allowSurfaceOutputs: true
        )
    }

    @Test("Insert output properties are validated before delivery")
    func rejectsMalformedInsertOutputProperties() {
        let (baseCatalog, baseDefinition) = voiceWorkflowFixture(outputs: ["out.insert"])
        var widgets = baseCatalog.widgets
        widgets.append(workflowWidget(
            id: "out.insert",
            role: .output,
            typeTag: "insert",
            props: .object(["press_enter": .string("yes")])
        ))
        let catalog = WorkflowCatalog(widgets: widgets, workflows: [baseDefinition])

        #expect(throws: VoiceWorkflowCompileError.invalidProperty(
            widgetID: "out.insert",
            key: "press_enter",
            reason: "expected a boolean"
        )) {
            try VoiceWorkflowEngine().validate(
                definition: baseDefinition,
                catalog: catalog
            )
        }
    }

    @Test("Validation rejects an invalid explicit LLM failure policy")
    func rejectsInvalidFailurePolicy() {
        let (baseCatalog, definition) = voiceWorkflowFixture(failurePolicy: "ignore_everything")

        #expect(throws: VoiceWorkflowCompileError.invalidProperty(
            widgetID: "llm.fixture",
            key: "failure_policy",
            reason: "expected use_input or fail_run"
        )) {
            try VoiceWorkflowEngine().validate(
                definition: definition,
                catalog: baseCatalog
            )
        }
    }

    @Test("Validation rejects malformed processor properties before a recipe is offered")
    func rejectsMalformedProcessorProperties() throws {
        let (baseCatalog, definition) = voiceWorkflowFixture()
        var widgets = baseCatalog.widgets
        let sttIndex = try #require(widgets.firstIndex { $0.id == "stt.fixture" })
        guard case .object(var props) = widgets[sttIndex].props else {
            Issue.record("expected object props")
            return
        }
        props["temperature"] = .number(1.5)
        widgets[sttIndex].props = .object(props)

        #expect(throws: VoiceWorkflowCompileError.invalidProperty(
            widgetID: "stt.fixture",
            key: "temperature",
            reason: "expected a finite number in 0.0...1.0"
        )) {
            try VoiceWorkflowEngine().validate(
                definition: definition,
                catalog: WorkflowCatalog(widgets: widgets, workflows: [definition])
            )
        }
    }

    @Test("Desktop LLM widgets without an iOS failure policy default to use_input")
    func missingFailurePolicyDefaultsToUseInput() async throws {
        let (baseCatalog, definition) = voiceWorkflowFixture()
        var widgets = baseCatalog.widgets
        let llmIndex = try #require(widgets.firstIndex(where: { $0.id == "llm.fixture" }))
        guard case .object(var props) = widgets[llmIndex].props else {
            Issue.record("expected object props")
            return
        }
        props.removeValue(forKey: "failure_policy")
        widgets[llmIndex].props = .object(props)
        let catalog = WorkflowCatalog(widgets: widgets, workflows: [definition])
        let stt = WorkflowSTTDouble(.succeed("input"))
        let llm = WorkflowLLMDouble(.fail)
        let output = WorkflowOutputDouble()
        let plan = try VoiceWorkflowEngine().compile(
            definition: definition,
            catalog: catalog,
            resolver: VoiceWorkflowRuntimeResolver(
                resolveSTT: { _ in .init(provider: stt) },
                resolveLLM: { _ in .init(provider: llm) },
                resolveOutput: { _ in output }
            )
        )

        let result = try await VoiceWorkflowEngine().run(
            VoiceWorkflowRunInput(audioData: Data([1])),
            using: plan
        )
        #expect(result.finalText == "input")
        #expect(result.degradations == [.llmFailedUsingInput(widgetID: "llm.fixture")])
    }

    @Test("Operational validation rejects a missing explicit STT profile")
    func operationalValidationRejectsExplicitMissingSTT() {
        let (catalog, definition) = voiceWorkflowFixture()
        var config = AppConfig()
        config.modelProfiles = [ModelProfile(
            id: "llm-profile",
            name: "LLM",
            provider: "openai",
            modelID: "gpt-4o",
            capabilities: ["llm"]
        )]

        #expect(throws: VoiceWorkflowCompileError.resolutionFailed(
            widgetID: "stt.fixture",
            reason: "explicit STT model profile 'stt-profile' is unavailable"
        )) {
            try VoiceWorkflowOperationalValidator.validateMicrophone(
                definition: definition,
                catalog: catalog,
                config: config
            )
        }
    }

    @Test("Operational validation accepts desktop's explicit Apple Speech sentinel")
    func operationalValidationAcceptsAppleSpeechSentinel() throws {
        let (baseCatalog, definition) = voiceWorkflowFixture()
        var widgets = baseCatalog.widgets
        let sttIndex = try #require(widgets.firstIndex { $0.id == "stt.fixture" })
        guard case .object(var props) = widgets[sttIndex].props else {
            Issue.record("expected object props")
            return
        }
        props["model_profile"] = .string(ModelProfileReference.appleSpeech)
        widgets[sttIndex].props = .object(props)
        let catalog = WorkflowCatalog(widgets: widgets, workflows: [definition])
        var config = AppConfig()
        config.modelProfiles = [ModelProfile(
            id: "llm-profile",
            name: "LLM",
            provider: "openai",
            modelID: "gpt-4o",
            capabilities: ["llm"]
        )]

        _ = try VoiceWorkflowOperationalValidator.validateMicrophone(
            definition: definition,
            catalog: catalog,
            config: config
        )
    }

    @Test("Operational validation canonicalizes explicit profile references")
    func operationalValidationTrimsProfileReferences() throws {
        let (baseCatalog, definition) = voiceWorkflowFixture()
        var widgets = baseCatalog.widgets
        for id in ["stt.fixture", "llm.fixture"] {
            let index = try #require(widgets.firstIndex { $0.id == id })
            guard case .object(var props) = widgets[index].props,
                  let profile = props["model_profile"]?.stringValue else {
                Issue.record("expected model profile")
                return
            }
            props["model_profile"] = .string("  \(profile)  ")
            widgets[index].props = .object(props)
        }
        let catalog = WorkflowCatalog(widgets: widgets, workflows: [definition])
        var config = AppConfig()
        config.modelProfiles = [
            ModelProfile(
                id: "stt-profile", name: "STT", provider: "openai",
                modelID: "whisper-1", capabilities: ["stt"]
            ),
            ModelProfile(
                id: "llm-profile", name: "LLM", provider: "openai",
                modelID: "gpt-4o", capabilities: ["llm"]
            )
        ]

        _ = try VoiceWorkflowOperationalValidator.validateMicrophone(
            definition: definition,
            catalog: catalog,
            config: config
        )
    }

    @Test("Operational validation rejects a missing explicit LLM profile")
    func operationalValidationRejectsExplicitMissingLLM() {
        let (catalog, definition) = voiceWorkflowFixture()
        var config = AppConfig()
        config.modelProfiles = [ModelProfile(
            id: "stt-profile",
            name: "STT",
            provider: "openai",
            modelID: "whisper-1",
            capabilities: ["stt"]
        )]

        #expect(throws: VoiceWorkflowCompileError.resolutionFailed(
            widgetID: "llm.fixture",
            reason: "explicit LLM model profile 'llm-profile' is unavailable"
        )) {
            try VoiceWorkflowOperationalValidator.validateMicrophone(
                definition: definition,
                catalog: catalog,
                config: config
            )
        }
    }

    @Test("Operational validation rejects a profile endpoint that cannot be called")
    func operationalValidationRejectsInvalidEndpoint() throws {
        let (catalog, definition) = voiceWorkflowFixture()
        var config = AppConfig()
        config.modelProfiles = [
            ModelProfile(
                id: "stt-profile",
                name: "Broken STT",
                provider: "custom",
                modelID: "asr",
                baseURL: "not a URL",
                capabilities: ["stt"]
            ),
            ModelProfile(
                id: "llm-profile",
                name: "LLM",
                provider: "openai",
                modelID: "gpt-4o",
                capabilities: ["llm"]
            )
        ]

        #expect(throws: VoiceWorkflowCompileError.resolutionFailed(
            widgetID: "stt.fixture",
            reason: "STT model profile 'stt-profile' has an invalid endpoint"
        )) {
            try VoiceWorkflowOperationalValidator.validateMicrophone(
                definition: definition,
                catalog: catalog,
                config: config
            )
        }
    }

    @Test("Default LLM may be absent only when use_input makes degradation explicit")
    func operationalValidationHonorsLLMFailurePolicy() throws {
        let (baseCatalog, definition) = voiceWorkflowFixture()
        var widgets = baseCatalog.widgets
        let llmIndex = try #require(widgets.firstIndex { $0.id == "llm.fixture" })
        guard case .object(var props) = widgets[llmIndex].props else {
            Issue.record("expected object props")
            return
        }
        props["model_profile"] = .string("")
        widgets[llmIndex].props = .object(props)
        var config = AppConfig()
        config.modelProfiles = [ModelProfile(
            id: "stt-profile",
            name: "STT",
            provider: "openai",
            modelID: "whisper-1",
            capabilities: ["stt"]
        )]
        let degradableCatalog = WorkflowCatalog(widgets: widgets, workflows: [definition])

        _ = try VoiceWorkflowOperationalValidator.validateMicrophone(
            definition: definition,
            catalog: degradableCatalog,
            config: config
        )

        guard case .object(var failProps) = widgets[llmIndex].props else { return }
        failProps["failure_policy"] = .string("fail_run")
        widgets[llmIndex].props = .object(failProps)
        let strictCatalog = WorkflowCatalog(widgets: widgets, workflows: [definition])
        #expect(throws: VoiceWorkflowCompileError.resolutionFailed(
            widgetID: "llm.fixture",
            reason: "LLM model profile 'default' is unavailable"
        )) {
            try VoiceWorkflowOperationalValidator.validateMicrophone(
                definition: definition,
                catalog: strictCatalog,
                config: config
            )
        }
    }
}

@Suite(.serialized)
struct VoiceWorkflowPlanFactoryTests {
    @Test("Shared plan factory freezes provider and vocabulary dependencies")
    func freezesProductionDependencies() async throws {
        let suiteName = "VoiceWorkflowPlanFactoryTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let vocabStore = VocabStore(defaults: defaults, storageKey: "vocab")
        vocabStore.upsert(VocabBook(
            id: "book.fixture",
            name: "Fixture",
            terms: ["Fonos"],
            rules: [VocabRule(from: "phone us", to: "Fonos")]
        ))

        var config = AppConfig()
        config.modelProfiles = [
            ModelProfile(
                id: "stt-profile",
                name: "Configured STT",
                provider: "openai",
                modelID: "whisper-1",
                capabilities: ["stt"]
            ),
            ModelProfile(
                id: "llm-profile",
                name: "Configured LLM",
                provider: "openai",
                modelID: "gpt-4o",
                capabilities: ["llm"]
            )
        ]
        let (catalog, definition) = voiceWorkflowFixture()
        let stt = WorkflowSTTDouble(.succeed("phone us ships"))
        let llm = WorkflowLLMDouble(.succeed("Final"))
        let output = WorkflowOutputDouble()
        let compilation = try VoiceWorkflowPlanFactory(
            config: config,
            vocabStore: vocabStore,
            sttProviderOverride: stt,
            llmProviderOverride: llm,
            llmOverrideName: "Test LLM"
        ).compile(
            definition: definition,
            catalog: catalog,
            legacyScopeID: nil,
            resolveOutput: { _ in output }
        )

        // A later edit must not alter the already compiled run.
        vocabStore.upsert(VocabBook(
            id: "book.fixture",
            name: "Changed",
            terms: ["Changed"],
            rules: [VocabRule(from: "phone us", to: "Changed")]
        ))
        let result = try await VoiceWorkflowEngine().run(
            VoiceWorkflowRunInput(audioData: Data([1])),
            using: compilation.plan
        )

        #expect(compilation.hasLLM)
        #expect(compilation.hasConfiguredLLM)
        #expect(compilation.sttProviderName == "Configured STT")
        #expect(compilation.llmProviderName == "Test LLM")
        #expect(result.rawText == "Fonos ships")
        #expect(await stt.calls.first?.vocabulary == ["Fonos"])
        #expect(await llm.calls.first?.text == "Fonos ships")
        #expect(await output.texts == ["Final"])
    }

    @Test("Shared plan factory preserves explicit profile validation")
    func rejectsMissingExplicitProfile() {
        let (catalog, definition) = voiceWorkflowFixture()
        let factory = VoiceWorkflowPlanFactory(
            config: AppConfig(),
            vocabStore: VocabStore()
        )

        #expect(throws: VoiceWorkflowCompileError.resolutionFailed(
            widgetID: "stt.fixture",
            reason: "explicit STT model profile 'stt-profile' is unavailable"
        )) {
            try factory.compile(
                definition: definition,
                catalog: catalog,
                legacyScopeID: nil,
                resolveOutput: { _ in ReturnToCallerVoiceWorkflowOutput() }
            )
        }
    }
}

struct VoiceWorkflowExecutionTests {
    @Test("Compile freezes providers, widget config, and vocabulary before execution")
    func compilationFreezesEveryDependency() throws {
        let stt = WorkflowSTTDouble(.succeed("phone us"))
        let llm = WorkflowLLMDouble(.succeed("Fonos"))
        let output = WorkflowOutputDouble()
        let counter = WorkflowResolutionCounter()
        _ = try compileFixture(stt: stt, llm: llm, output: output, counter: counter)

        #expect(counter.value("stt:stt.fixture") == 1)
        #expect(counter.value("llm:llm.fixture") == 1)
        #expect(counter.value("vocab:stt.fixture") == 1)
        #expect(counter.value("vocab:llm.fixture") == 1)
        #expect(counter.value("output:out.return") == 1)
    }

    @Test("Dynamic execution applies STT config, vocabulary, LLM config, and output in order")
    func success() async throws {
        let stt = WorkflowSTTDouble(.succeed("phone us ships"))
        let llm = WorkflowLLMDouble(.succeed("Fonos ships."))
        let output = WorkflowOutputDouble()
        let plan = try compileFixture(stt: stt, llm: llm, output: output)
        let runID = UUID()

        let result = try await VoiceWorkflowEngine().run(
            VoiceWorkflowRunInput(
                runID: runID,
                audioData: Data([1, 2, 3]),
                sourceAcquisitionDuration: 1.25
            ),
            using: plan
        )

        #expect(result.runID == runID)
        #expect(result.workflowID == "wf.fixture")
        #expect(result.providerTranscript == "phone us ships")
        #expect(result.rawText == "Fonos ships")
        #expect(result.finalText == "Fonos ships.")
        #expect(result.degradations.isEmpty)
        #expect(result.timings.steps.map(\.step.widgetID) == [
            "src.mic", "stt.fixture", "llm.fixture", "out.return"
        ])
        #expect(result.timings.duration(forWidgetID: "src.mic") == 1.25)
        #expect(result.timings.total == VoiceWorkflowTimings.processingTotal(
            result.timings.steps
        ))
        #expect(result.timings.total == result.timings.steps
            .filter { $0.step.role != .source }
            .reduce(0) { $0 + $1.duration })
        #expect(terminalCount(result.trace) == 1)
        #expect(!String(describing: result.trace).contains("phone us ships"))
        #expect(!String(describing: result.trace).contains("Fonos ships."))

        let sttCalls = await stt.calls
        #expect(sttCalls == [.init(
            language: "en-US",
            vocabulary: ["Fonos"],
            promptHint: "Meeting words",
            temperature: 0.35
        )])
        let llmCalls = await llm.calls
        #expect(llmCalls.count == 1)
        #expect(llmCalls.first?.text == "Fonos ships")
        #expect(llmCalls.first?.configuration.temperature == 0.42)
        #expect(llmCalls.first?.configuration.maxTokens == 777)
        #expect(llmCalls.first?.configuration.systemPrompt?.contains("Domain vocabulary: Fonos") == true)
        #expect(llmCalls.first?.configuration.userMessage(for: "X") ==
            "Rewrite X for German\n\nIMPORTANT: Output in French.")
        #expect(await output.texts == ["Fonos ships."])
    }

    @Test("use_input degrades explicitly and still delivers the LLM input")
    func llmUseInputFallback() async throws {
        let stt = WorkflowSTTDouble(.succeed("phone us"))
        let llm = WorkflowLLMDouble(.fail)
        let output = WorkflowOutputDouble()
        let plan = try compileFixture(stt: stt, llm: llm, output: output)

        let result = try await VoiceWorkflowEngine().run(
            VoiceWorkflowRunInput(audioData: Data([1])),
            using: plan
        )

        #expect(result.providerTranscript == "phone us")
        #expect(result.rawText == "Fonos")
        #expect(result.finalText == "Fonos")
        #expect(result.degradations == [.llmFailedUsingInput(widgetID: "llm.fixture")])
        #expect(hasFinished(result.trace, widgetID: "llm.fixture", outcome: .fallback))
        #expect(await output.texts == ["Fonos"])
        #expect(terminalCount(result.trace) == 1)
    }

    @Test("fail_run emits one failed terminal and does not deliver output")
    func llmFailRun() async throws {
        let stt = WorkflowSTTDouble(.succeed("input"))
        let llm = WorkflowLLMDouble(.fail)
        let output = WorkflowOutputDouble()
        let plan = try compileFixture(
            failurePolicy: "fail_run",
            stt: stt,
            llm: llm,
            output: output
        )
        let log = WorkflowEventLog()

        await #expect(throws: VoiceWorkflowTestError.self) {
            try await VoiceWorkflowEngine().run(
                VoiceWorkflowRunInput(audioData: Data([1])),
                using: plan,
                onEvent: { event in await log.append(event) }
            )
        }
        let events = await log.events
        #expect(hasFinished(events, widgetID: "llm.fixture", outcome: .failed))
        #expect(terminalCount(events) == 1)
        #expect(await output.texts.isEmpty)
    }

    @Test("Dry run traces every output as intercepted and performs no delivery")
    func dryRunInterceptsOutput() async throws {
        let stt = WorkflowSTTDouble(.succeed("input"))
        let llm = WorkflowLLMDouble(.succeed("output"))
        let output = WorkflowOutputDouble()
        let recorder = WorkflowRecorderLog()
        let plan = try compileFixture(stt: stt, llm: llm, output: output)

        let result = try await VoiceWorkflowEngine().run(
            VoiceWorkflowRunInput(audioData: Data([1]), dryRun: true),
            using: plan,
            recorder: { value in await recorder.append(value) }
        )

        #expect(result.finalText == "output")
        #expect(hasFinished(result.trace, widgetID: "out.return", outcome: .intercepted))
        #expect(result.timings.duration(forWidgetID: "out.return") == 0)
        #expect(await output.texts.isEmpty)
        #expect(await recorder.values.isEmpty)
    }

    @Test("Output failure stops delivery and produces exactly one terminal")
    func outputFailure() async throws {
        let stt = WorkflowSTTDouble(.succeed("input"))
        let llm = WorkflowLLMDouble(.succeed("output"))
        let output = WorkflowOutputDouble(shouldFail: true)
        let plan = try compileFixture(stt: stt, llm: llm, output: output)
        let log = WorkflowEventLog()
        let recorder = WorkflowRecorderLog()

        await #expect(throws: VoiceWorkflowTestError.self) {
            try await VoiceWorkflowEngine().run(
                VoiceWorkflowRunInput(audioData: Data([1])),
                using: plan,
                onEvent: { event in await log.append(event) },
                recorder: { value in await recorder.append(value) }
            )
        }
        let events = await log.events
        #expect(hasFinished(events, widgetID: "out.return", outcome: .failed))
        #expect(terminalCount(events) == 1)
        let recorded = await recorder.values
        #expect(recorded.count == 1)
        #expect(recorded.first?.rawText == "input")
        #expect(recorded.first?.finalText == "output")
    }

    @Test("Outputs follow desktop delivery order and a failure skips later outputs")
    func orderedOutputFailureSkipsRemainder() async throws {
        let stt = WorkflowSTTDouble(.succeed("input"))
        let llm = WorkflowLLMDouble(.succeed("output"))
        let first = WorkflowOutputDouble(shouldFail: true)
        let second = WorkflowOutputDouble()
        let (catalog, definition) = voiceWorkflowFixture(outputs: [
            "out.return", "out.clipboard"
        ])
        let plan = try VoiceWorkflowEngine().compile(
            definition: definition,
            catalog: catalog,
            resolver: VoiceWorkflowRuntimeResolver(
                resolveSTT: { _ in .init(provider: stt) },
                resolveLLM: { _ in .init(provider: llm) },
                resolveOutput: { widget in
                    widget.id == "out.return" ? first : second
                }
            )
        )

        await #expect(throws: VoiceWorkflowTestError.output) {
            _ = try await VoiceWorkflowEngine().run(
                VoiceWorkflowRunInput(audioData: Data([1])),
                using: plan
            )
        }
        #expect(await first.texts.isEmpty)
        #expect(await second.texts.isEmpty)
    }

    @Test("Cancellation emits a cancelled step and one cancelled terminal")
    func cancellation() async throws {
        let stt = WorkflowSTTDouble(.block)
        let llm = WorkflowLLMDouble(.succeed("output"))
        let output = WorkflowOutputDouble()
        let plan = try compileFixture(stt: stt, llm: llm, output: output)
        let log = WorkflowEventLog()
        let task = Task {
            try await VoiceWorkflowEngine().run(
                VoiceWorkflowRunInput(audioData: Data([1])),
                using: plan,
                onEvent: { event in await log.append(event) }
            )
        }

        for _ in 0..<2_000 {
            let events = await log.events
            if events.contains(where: {
                guard case .stepStarted(_, _, let step) = $0 else { return false }
                return step.widgetID == "stt.fixture"
            }) { break }
            await Task.yield()
        }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }

        let events = await log.events
        #expect(hasFinished(events, widgetID: "stt.fixture", outcome: .cancelled))
        #expect(terminalCount(events) == 1)
        #expect(await output.texts.isEmpty)
    }

    @Test("Provided-audio workflows require the matching source envelope")
    func providedAudioSource() async throws {
        let stt = WorkflowSTTDouble(.succeed("input"))
        let llm = WorkflowLLMDouble(.succeed("output"))
        let output = WorkflowOutputDouble()
        let plan = try compileFixture(
            sourceType: "provided_audio",
            stt: stt,
            llm: llm,
            output: output
        )

        await #expect(throws: VoiceWorkflowRuntimeError.sourceInputMismatch(
            expected: .providedAudio,
            actual: .microphone
        )) {
            _ = try await VoiceWorkflowEngine().run(
                VoiceWorkflowRunInput(audioData: Data([1]), source: .microphone),
                using: plan
            )
        }

        let result = try await VoiceWorkflowEngine().run(
            VoiceWorkflowRunInput(audioData: Data([1]), source: .providedAudio),
            using: plan
        )
        #expect(result.finalText == "output")
    }
}

struct VoiceRecipeDraftTests {
    @Test("untouched builtin materializes without redundant widget overlays")
    func untouchedBuiltinIsIdentity() throws {
        let definition = try #require(
            WorkflowCatalog.builtIn.workflow(id: "wf.dictation")
        )
        let draft = VoiceRecipeDraft.make(
            definition: definition,
            catalog: WorkflowCatalog.builtIn
        )

        let result = draft.materializedResult()

        #expect(result.definition == definition)
        #expect(result.widgetOverlays.isEmpty)
    }

    @Test("editing a builtin clones it and preserves unknown properties")
    func copyOnWritePreservesUnknownProperties() throws {
        var sharedSTT = try #require(
            WorkflowCatalog.builtIn.widget(id: "stt.default")
        )
        guard case .object(var props) = sharedSTT.props else {
            Issue.record("expected STT props")
            return
        }
        props["future_tuning"] = .object([
            "enabled": .bool(true),
            "weight": .integer(7)
        ])
        sharedSTT.props = .object(props)
        let definition = WorkflowDefinition(
            id: "wf.copy-on-write",
            name: "Copy on write",
            source: "src.mic-hold",
            processors: [sharedSTT.id],
            outputs: ["out.insert"]
        )
        var catalog = WorkflowCatalog.builtIn
        catalog.widgets.removeAll { $0.id == sharedSTT.id }
        catalog.widgets.append(sharedSTT)
        catalog.workflows.append(definition)
        var draft = VoiceRecipeDraft.make(
            definition: definition,
            catalog: catalog
        )

        draft.stt.prompt = "Project names"
        let result = draft.materializedResult()
        let clonedID = try #require(result.definition.processors.first)
        let cloned = try #require(result.widgetOverlays.first { $0.id == clonedID })

        #expect(clonedID != sharedSTT.id)
        #expect(!cloned.builtin)
        #expect(cloned.props["stt_prompt"]?.stringValue == "Project names")
        #expect(cloned.props["future_tuning"] == props["future_tuning"])
    }

    @Test("materialization preserves multiple LLM processor order")
    func preservesLLMOrder() {
        let definition = WorkflowDefinition(
            id: "wf.two-llms",
            name: "Two LLMs",
            source: "src.mic-hold",
            processors: ["stt.default", "llm.formal", "llm.polish"],
            outputs: ["out.insert"]
        )
        var catalog = WorkflowCatalog.builtIn
        catalog.workflows.append(definition)

        let result = VoiceRecipeDraft.make(
            definition: definition,
            catalog: catalog
        ).materializedResult()

        #expect(result.definition.processors == [
            "stt.default", "llm.formal", "llm.polish"
        ])
    }

    @Test("press-enter copy-on-write keeps declared output delivery order")
    func preservesOutputOrderAndProperties() throws {
        let definition = WorkflowDefinition(
            id: "wf.ordered-outputs",
            name: "Ordered outputs",
            triggers: [.unknown(kind: "future_surface", fields: [
                "slot": .string("side")
            ])],
            source: "src.mic-hold",
            processors: ["stt.default"],
            outputs: ["out.clipboard", "out.insert"]
        )
        var catalog = WorkflowCatalog.builtIn
        catalog.workflows.append(definition)
        var draft = VoiceRecipeDraft.make(
            definition: definition,
            catalog: catalog
        )

        draft.insertOutput.pressEnter = true
        let result = draft.materializedResult()
        let insertID = try #require(result.definition.outputs.last)
        let insert = try #require(result.widgetOverlays.first { $0.id == insertID })

        #expect(result.definition.outputs.first == "out.clipboard")
        #expect(insertID != "out.insert")
        #expect(insert.props["press_enter"]?.boolValue == true)
        #expect(insert.props["strategy"]?.stringValue == "paste")
        #expect(result.definition.triggers == definition.triggers)
    }

    @Test("missing component references surface blocking draft issues")
    func reportsMissingReferences() {
        let definition = WorkflowDefinition(
            id: "wf.broken",
            name: "Broken",
            source: "src.missing",
            processors: ["processor.missing"],
            outputs: ["output.missing"]
        )

        let draft = VoiceRecipeDraft.make(
            definition: definition,
            catalog: WorkflowCatalog.builtIn
        )

        #expect(draft.blockingIssues.contains {
            $0.contains("source component is missing")
        })
        #expect(draft.blockingIssues.contains {
            $0.contains("must begin with one STT processor")
        })
        #expect(draft.blockingIssues.contains {
            $0.contains("Output 'output.missing' is missing")
        })
    }
}

@Suite(.serialized)
struct LLMRequestConfigurationTests {
    @Test("Workflow request config mirrors desktop target/output language assembly")
    func canonicalPromptAssembly() {
        let config = LLMRequestConfiguration(
            systemPrompt: nil,
            userTemplate: "Translate {text} to {target_lang}",
            temperature: 0.2,
            maxTokens: 4096,
            outputLanguage: "Chinese",
            translateTarget: "French",
            glossary: "\n\nDomain vocabulary: Fonos."
        )

        #expect(config.systemPrompt == "Domain vocabulary: Fonos.")
        #expect(config.userMessage(for: "hello") ==
            "Translate hello to French\n\nIMPORTANT: Output in Chinese.")
        #expect(config.messages(for: "hello").map { $0["role"] } == ["system", "user"])
    }

    @Test("Workflow request config uses canonical llm widget defaults")
    func canonicalDefaults() {
        let config = LLMRequestConfiguration()
        #expect(config.systemPrompt == nil)
        #expect(config.userMessage(for: "hello") == "hello")
        #expect(config.temperature == 0.1)
        #expect(config.maxTokens == 4096)
        #expect(config.outputLanguage == "auto")
    }

    @Test("Generic workflow LLM requests trim output and reject whitespace-only completions")
    func genericRequestRejectsEmptyResponse() async throws {
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [WorkflowLLMURLProtocol.self]
        let service = authorizedLLMService(
            session: URLSession(configuration: sessionConfiguration),
            apiKey: "test"
        )

        WorkflowLLMURLProtocol.responseContent = "  complete  \n"
        let output = try await service.process(
            text: "input",
            configuration: LLMRequestConfiguration()
        )
        #expect(output == "complete")

        WorkflowLLMURLProtocol.responseContent = "  \n  "
        await #expect(throws: LLMError.emptyResponse) {
            _ = try await service.process(
                text: "input",
                configuration: LLMRequestConfiguration()
            )
        }
    }
}
