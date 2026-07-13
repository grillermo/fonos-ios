// P1-1 (docs/ROADMAP.md): custom vocabulary — vocab books with terms +
// correction rules, JSON-compatible with fonos-core vocab.rs so books and
// scenario files interchange with desktop. Test cases are ports of the
// fonos-core vocab.rs unit tests.
//
// Run: xcodebuild test -scheme FonosApp -only-testing:FonosAppTests/VocabTests

import Testing
import Foundation
@testable import FonosApp

// MARK: - Fixtures

private func book(_ id: String, terms: [String] = [], rules: [VocabRule] = []) -> VocabBook {
    VocabBook(id: id, name: id, enabled: true, terms: terms, rules: rules)
}

private func lit(_ from: String, _ to: String) -> VocabRule {
    VocabRule(from: from, to: to, kind: .literal, caseInsensitive: true)
}

// MARK: - Rule application (ports of vocab.rs tests)

struct VocabTests {

    @Test("literal rule is case-insensitive and word-boundary guarded")
    func literalRuleCaseInsensitiveWordBoundary() {
        let b = book("t", rules: [lit("my sequel", "MySQL")])
        let out = VocabApplier.applyRules("I use My Sequel and my sequel daily", books: [b])
        #expect(out == "I use MySQL and MySQL daily")
    }

    @Test("literal rule respects word boundaries")
    func literalRuleRespectsWordBoundaries() {
        let b = book("t", rules: [lit("art", "ART")])
        #expect(VocabApplier.applyRules("art starts here", books: [b]) == "ART starts here")
    }

    @Test("literal rule honours case sensitivity when disabled")
    func literalRuleCaseSensitiveWhenDisabled() {
        let rule = VocabRule(from: "k8s", to: "K8s", kind: .literal, caseInsensitive: false)
        let b = book("t", rules: [rule])
        #expect(VocabApplier.applyRules("k8s and K8S", books: [b]) == "K8s and K8S")
    }

    @Test("CJK rule matches as a substring (no word boundaries)")
    func cjkRuleMatchesAsSubstring() {
        let b = book("t", rules: [lit("库伯内提斯", "Kubernetes")])
        #expect(VocabApplier.applyRules("我们用库伯内提斯部署", books: [b]) == "我们用Kubernetes部署")
    }

    @Test("regex rule collapses whitespace variants")
    func regexRule() {
        let rule = VocabRule(from: #"k8\s+s"#, to: "k8s", kind: .regex, caseInsensitive: true)
        let b = book("t", rules: [rule])
        #expect(VocabApplier.applyRules("deploy to K8 s now", books: [b]) == "deploy to k8s now")
    }

    @Test("invalid regex is skipped, later rules still apply")
    func invalidRegexSkipped() {
        let bad = VocabRule(from: "([", to: "x", kind: .regex, caseInsensitive: true)
        let b = book("t", rules: [bad, lit("foo", "bar")])
        #expect(VocabApplier.applyRules("foo", books: [b]) == "bar")
    }

    @Test("rules apply in book order then rule order (chaining)")
    func rulesApplyInOrder() {
        let b1 = book("a", rules: [lit("alpha", "beta")])
        let b2 = book("b", rules: [lit("beta", "gamma")])
        #expect(VocabApplier.applyRules("alpha", books: [b1, b2]) == "gamma")
    }

    // MARK: - Effective books & terms

    @Test("effective books: global then mode, deduplicated, disabled skipped")
    func effectiveBooksDedupAndSkipDisabled() {
        var disabled = book("off", terms: ["X"])
        disabled.enabled = false
        let books = [book("g", terms: ["G"]), disabled, book("m", terms: ["M"])]
        let eff = VocabApplier.effectiveBooks(
            books: books,
            globalIDs: ["g", "off"],
            modeIDs: ["m", "g", "missing"]
        )
        #expect(eff.map(\.id) == ["g", "m"])
    }

    @Test("collectTerms trims, dedups, preserves order")
    func collectTermsDedups() {
        let b1 = book("a", terms: ["Kubernetes", "fonos"])
        let b2 = book("b", terms: ["fonos", " Istio "])
        #expect(VocabApplier.collectTerms([b1, b2]) == ["Kubernetes", "fonos", "Istio"])
    }

    // MARK: - STT prompt & glossary

    @Test("STT prompt appends glossary within budget")
    func sttPromptAppendsGlossary() {
        let out = VocabApplier.buildSTTPrompt(
            base: "Tech dictation.",
            terms: ["Kubernetes", "kubectl"],
            budgetChars: VocabApplier.sttPromptBudgetChars
        )
        #expect(out == "Tech dictation. Vocabulary: Kubernetes, kubectl.")
    }

    @Test("STT prompt truncates terms to fit the budget")
    func sttPromptTruncates() {
        let terms = (0..<100).map { String(format: "term%02d", $0) }
        let out = VocabApplier.buildSTTPrompt(base: "", terms: terms, budgetChars: 60)
        #expect(out.count <= 60)
        #expect(out.hasPrefix("Vocabulary: term00"))
    }

    @Test("STT prompt is unchanged without terms")
    func sttPromptUnchangedWithoutTerms() {
        #expect(VocabApplier.buildSTTPrompt(base: "base", terms: [], budgetChars: 600) == "base")
        #expect(VocabApplier.buildSTTPrompt(base: "", terms: [], budgetChars: 600) == "")
    }

    @Test("glossary block is nil when empty, mentions terms otherwise")
    func glossaryBlock() {
        #expect(VocabApplier.buildGlossaryBlock(terms: []) == nil)
        let block = VocabApplier.buildGlossaryBlock(terms: ["MySQL"])
        #expect(block?.contains("MySQL") == true)
        #expect(block?.hasPrefix("\n\nDomain vocabulary:") == true)
    }

    // MARK: - JSON contract (fonos-core interchange)

    @Test("decoding tolerates missing keys like serde(default)")
    func decodeDefaults() throws {
        let bookData = #"{"id":"x","name":"X"}"#.data(using: .utf8)!
        let b = try JSONDecoder().decode(VocabBook.self, from: bookData)
        #expect(b.enabled && b.terms.isEmpty && b.rules.isEmpty)

        let ruleData = #"{"from":"a","to":"b"}"#.data(using: .utf8)!
        let r = try JSONDecoder().decode(VocabRule.self, from: ruleData)
        #expect(r.kind == .literal)
        #expect(r.caseInsensitive)
    }

    @Test("encoding uses fonos-core snake_case keys")
    func encodeSnakeCase() throws {
        let rule = VocabRule(from: "a", to: "b", kind: .regex, caseInsensitive: false)
        let data = try JSONEncoder().encode(book("x", rules: [rule]))
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let rules = obj?["rules"] as? [[String: Any]]
        #expect(rules?.first?["case_insensitive"] as? Bool == false)
        #expect(rules?.first?["kind"] as? String == "regex")
        #expect(rules?.first?["from"] as? String == "a")
    }

    @Test("desktop-exported book JSON round-trips")
    func desktopBookRoundTrip() throws {
        let json = """
        {"id":"tech","name":"Tech Terms","enabled":true,
         "terms":["Kubernetes","fonos"],
         "rules":[{"from":"my sequel","to":"MySQL","kind":"literal","case_insensitive":true}]}
        """.data(using: .utf8)!
        let b = try JSONDecoder().decode(VocabBook.self, from: json)
        #expect(b.name == "Tech Terms")
        #expect(b.terms == ["Kubernetes", "fonos"])
        #expect(b.rules.first?.to == "MySQL")
        let out = VocabApplier.applyRules("I love my sequel", books: [b])
        #expect(out == "I love MySQL")
    }
}

// MARK: - VocabStore (persistence + mounts + correction capture)

@MainActor
struct VocabStoreTests {

    private func freshDefaults() -> UserDefaults {
        let name = "vocab-tests-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return d
    }

    @Test("books persist across store instances")
    func persistenceRoundTrip() {
        let defaults = freshDefaults()
        let store = VocabStore(defaults: defaults)
        store.upsert(VocabBook(id: "tech", name: "Tech", terms: ["Kubernetes"]))
        let reloaded = VocabStore(defaults: defaults)
        #expect(reloaded.books.map(\.id) == ["tech"])
        #expect(reloaded.book(id: "tech")?.terms == ["Kubernetes"])
    }

    @Test("global and mode mounts resolve to effective books in order")
    func mountsResolve() {
        let store = VocabStore(defaults: freshDefaults())
        store.upsert(VocabBook(id: "g", name: "Global book"))
        store.upsert(VocabBook(id: "m", name: "Mode book"))
        store.setMounted(["g"], forKey: VocabStore.globalMountKey)
        store.setMounted(["m"], forKey: VocabStore.modeMountKey("polish"))
        #expect(store.effectiveBooks(modeID: "polish").map(\.id) == ["g", "m"])
        #expect(store.effectiveBooks(modeID: "raw").map(\.id) == ["g"])
    }

    @Test("notebook mounts resolve alongside global")
    func notebookMountsResolve() {
        let store = VocabStore(defaults: freshDefaults())
        let nbID = UUID()
        store.upsert(VocabBook(id: "g", name: "G"))
        store.upsert(VocabBook(id: "n", name: "N"))
        store.setMounted(["g"], forKey: VocabStore.globalMountKey)
        store.setMounted(["n"], forKey: VocabStore.notebookMountKey(nbID))
        #expect(store.effectiveBooks(notebookID: nbID).map(\.id) == ["g", "n"])
        #expect(store.effectiveBooks(notebookID: UUID()).map(\.id) == ["g"])
    }

    @Test("addCorrectionRule creates a globally-mounted Corrections book")
    func correctionCapture() {
        let store = VocabStore(defaults: freshDefaults())
        store.addCorrectionRule(from: "my sequel", to: "MySQL")
        store.addCorrectionRule(from: "cube control", to: "kubectl")
        let corrections = store.book(id: VocabStore.correctionsBookID)
        #expect(corrections?.rules.count == 2)
        #expect(store.mountedIDs(forKey: VocabStore.globalMountKey).contains(VocabStore.correctionsBookID))
        let out = VocabApplier.applyRules("use my sequel and cube control",
                                          books: store.effectiveBooks(modeID: nil))
        #expect(out == "use MySQL and kubectl")
    }

    @Test("two store instances over the same defaults stay consistent")
    func crossInstanceConsistency() {
        let defaults = freshDefaults()
        let a = VocabStore(defaults: defaults)
        let b = VocabStore(defaults: defaults)
        a.upsert(VocabBook(id: "x", name: "X"))
        #expect(b.books.map(\.id) == ["x"])
        b.addCorrectionRule(from: "teh", to: "the")
        #expect(a.book(id: VocabStore.correctionsBookID)?.rules.count == 1)
    }

    @Test("addCorrectionTerm collects terms into the Corrections book")
    func correctionTermCapture() {
        let store = VocabStore(defaults: freshDefaults())
        store.addCorrectionTerm(" Kubernetes ")
        store.addCorrectionTerm("Kubernetes")
        #expect(store.book(id: VocabStore.correctionsBookID)?.terms == ["Kubernetes"])
        #expect(store.mountedIDs(forKey: VocabStore.globalMountKey).contains(VocabStore.correctionsBookID))
    }

    @Test("removing a book also unmounts it everywhere")
    func removeUnmounts() {
        let store = VocabStore(defaults: freshDefaults())
        store.upsert(VocabBook(id: "x", name: "X"))
        store.setMounted(["x"], forKey: VocabStore.globalMountKey)
        store.removeBook(id: "x")
        #expect(store.books.isEmpty)
        #expect(store.mountedIDs(forKey: VocabStore.globalMountKey).isEmpty)
    }
}

// MARK: - Pipeline integration

/// STT mock that records the vocabulary terms it was offered.
private final class VocabRecordingSTT: STTProvider, @unchecked Sendable {
    let transcript: String
    var receivedVocabulary: [String]?
    var receivedPromptHint: String?
    init(transcript: String) { self.transcript = transcript }

    func transcribe(audioData: Data, language: String?) async throws -> String {
        transcript
    }

    func transcribe(audioData: Data, language: String?, vocabulary: [String], promptHint: String) async throws -> String {
        receivedVocabulary = vocabulary
        receivedPromptHint = promptHint
        return transcript
    }
}

/// Captures the LLM request body so tests can inspect the system prompt.
private final class GlossaryCaptureURLProtocol: URLProtocol {
    nonisolated(unsafe) static var lastSystemPrompt: String?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        var body = request.httpBody
        if body == nil, let stream = request.httpBodyStream {
            stream.open()
            var data = Data()
            let bufSize = 4096
            let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: bufSize)
            defer { buf.deallocate() }
            while stream.hasBytesAvailable {
                let n = stream.read(buf, maxLength: bufSize)
                if n > 0 { data.append(buf, count: n) }
            }
            stream.close()
            body = data
        }
        if let body,
           let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
           let messages = json["messages"] as? [[String: String]] {
            Self.lastSystemPrompt = messages.first(where: { $0["role"] == "system" })?["content"]
        }
        let reply = #"{"choices":[{"message":{"role":"assistant","content":"ok"},"finish_reason":"stop"}]}"#
        let resp = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: reply.data(using: .utf8)!)
        client?.urlProtocolDidFinishLoading(self)
    }
}

@Suite(.serialized)
struct VocabPipelineTests {

    private func freshStore() -> VocabStore {
        let name = "vocab-pipeline-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return VocabStore(defaults: d)
    }

    private func storeWithGlobalBook() -> VocabStore {
        let store = freshStore()
        store.upsert(VocabBook(
            id: "tech", name: "Tech",
            terms: ["MySQL", "Kubernetes"],
            rules: [VocabRule(from: "my sequel", to: "MySQL")]
        ))
        store.setMounted(["tech"], forKey: VocabStore.globalMountKey)
        return store
    }

    @Test("dictation pipeline applies correction rules to the transcript")
    func dictationAppliesRules() async throws {
        let vm = DictationViewModel(sttProvider: VocabRecordingSTT(transcript: "I use my sequel daily"))
        vm.vocabStore = storeWithGlobalBook()
        let result = try await vm.processAudio(Data(count: 44), language: nil, mode: .raw)
        #expect(result.text == "I use MySQL daily")
    }

    @Test("dictation pipeline offers vocabulary terms to the STT provider")
    func dictationOffersVocabularyToSTT() async throws {
        let stt = VocabRecordingSTT(transcript: "hello")
        let vm = DictationViewModel(sttProvider: stt)
        vm.vocabStore = storeWithGlobalBook()
        _ = try await vm.processAudio(Data(count: 44), language: nil, mode: .raw)
        #expect(stt.receivedVocabulary == ["MySQL", "Kubernetes"])
    }

    @Test("dictation pipeline appends the vocab glossary to the LLM system prompt")
    func dictationAppendsGlossaryToLLM() async throws {
        GlossaryCaptureURLProtocol.lastSystemPrompt = nil
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [GlossaryCaptureURLProtocol.self]
        let llm = authorizedLLMService(session: URLSession(configuration: config), apiKey: "sk-test")
        let vm = DictationViewModel(sttProvider: VocabRecordingSTT(transcript: "hi"), llmService: llm)
        vm.vocabStore = storeWithGlobalBook()
        _ = try await vm.processAudio(Data(count: 44), language: nil, mode: .polish)
        let prompt = GlossaryCaptureURLProtocol.lastSystemPrompt ?? ""
        #expect(prompt.contains("Domain vocabulary: MySQL, Kubernetes"))
    }

    @Test("note pipeline applies correction rules before storing")
    @MainActor
    func notePipelineAppliesRules() async throws {
        let noteService = NoteService()
        let notebook = noteService.createNotebook(title: "Vocab NB")
        let store = freshStore()
        store.upsert(VocabBook(id: "nb", name: "NB",
                               rules: [VocabRule(from: "my sequel", to: "MySQL")]))
        store.setMounted(["nb"], forKey: VocabStore.notebookMountKey(notebook.id))

        let vm = NoteViewModel(noteService: noteService,
                               sttProvider: VocabRecordingSTT(transcript: "my sequel notes"),
                               llmProvider: nil)
        vm.vocabStore = store
        await vm.recordAndStore(to: notebook.id, audioData: Data(count: 44))
        let entries = noteService.entriesForNotebook(notebook.id)
        #expect(entries.first?.rawText == "MySQL notes")
    }
}

// MARK: - WhisperSTT prompt biasing

private final class WhisperPromptCaptureURLProtocol: URLProtocol {
    nonisolated(unsafe) static var lastBody: Data?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        var body = request.httpBody
        if body == nil, let stream = request.httpBodyStream {
            stream.open()
            var data = Data()
            let bufSize = 4096
            let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: bufSize)
            defer { buf.deallocate() }
            while stream.hasBytesAvailable {
                let n = stream.read(buf, maxLength: bufSize)
                if n > 0 { data.append(buf, count: n) }
            }
            stream.close()
            body = data
        }
        Self.lastBody = body
        let resp = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: #"{"text":"ok"}"#.data(using: .utf8)!)
        client?.urlProtocolDidFinishLoading(self)
    }
}

@Suite(.serialized)
struct WhisperVocabPromptTests {

    @Test("WhisperSTT sends vocabulary as the multipart prompt field")
    func whisperSendsPrompt() async throws {
        WhisperPromptCaptureURLProtocol.lastBody = nil
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [WhisperPromptCaptureURLProtocol.self]
        let stt = authorizedWhisperSTT(session: URLSession(configuration: config), apiKey: "sk-test")
        _ = try await stt.transcribe(audioData: Data(count: 44), language: "en",
                                     vocabulary: ["Kubernetes", "kubectl"])
        let bodyText = String(data: WhisperPromptCaptureURLProtocol.lastBody ?? Data(),
                              encoding: .utf8) ?? ""
        #expect(bodyText.contains("name=\"prompt\""))
        #expect(bodyText.contains("Vocabulary: Kubernetes, kubectl."))
    }

    @Test("WhisperSTT omits the prompt field when vocabulary is empty")
    func whisperOmitsEmptyPrompt() async throws {
        WhisperPromptCaptureURLProtocol.lastBody = nil
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [WhisperPromptCaptureURLProtocol.self]
        let stt = authorizedWhisperSTT(session: URLSession(configuration: config), apiKey: "sk-test")
        _ = try await stt.transcribe(audioData: Data(count: 44), language: "en", vocabulary: [])
        let bodyText = String(data: WhisperPromptCaptureURLProtocol.lastBody ?? Data(),
                              encoding: .utf8) ?? ""
        #expect(!bodyText.contains("name=\"prompt\""))
    }

    // Desktop parity: the STT prompt folds the mode's prompt hint (base) with
    // the vocab glossary (build_stt_prompt in fonos-core).
    @Test("WhisperSTT folds the mode prompt hint and vocabulary into one prompt")
    func whisperFoldsHintAndVocab() async throws {
        WhisperPromptCaptureURLProtocol.lastBody = nil
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [WhisperPromptCaptureURLProtocol.self]
        let stt = authorizedWhisperSTT(session: URLSession(configuration: config), apiKey: "sk-test")
        _ = try await stt.transcribe(audioData: Data(count: 44), language: "en",
                                     vocabulary: ["MRI"], promptHint: "Medical dictation.")
        let bodyText = String(data: WhisperPromptCaptureURLProtocol.lastBody ?? Data(),
                              encoding: .utf8) ?? ""
        #expect(bodyText.contains("name=\"prompt\""))
        #expect(bodyText.contains("Medical dictation. Vocabulary: MRI."))
    }

    @Test("WhisperSTT sends only the hint when there is no vocabulary")
    func whisperHintOnly() async throws {
        WhisperPromptCaptureURLProtocol.lastBody = nil
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [WhisperPromptCaptureURLProtocol.self]
        let stt = authorizedWhisperSTT(session: URLSession(configuration: config), apiKey: "sk-test")
        _ = try await stt.transcribe(audioData: Data(count: 44), language: "en",
                                     vocabulary: [], promptHint: "Legal deposition.")
        let bodyText = String(data: WhisperPromptCaptureURLProtocol.lastBody ?? Data(),
                              encoding: .utf8) ?? ""
        #expect(bodyText.contains("Legal deposition."))
    }
}

// MARK: - VocabContext (shared pipeline helper used by all STT paths)

struct VocabContextTests {

    private func store() -> VocabStore {
        let name = "vocab-context-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        let s = VocabStore(defaults: d)
        s.upsert(VocabBook(id: "tech", name: "Tech", terms: ["MySQL", "Kubernetes"],
                           rules: [VocabRule(from: "my sequel", to: "MySQL")]))
        s.setMounted(["tech"], forKey: VocabStore.globalMountKey)
        return s
    }

    @Test("context(modeID:) collects terms from the effective books")
    func contextCollectsTerms() {
        let ctx = store().context(modeID: "raw")
        #expect(ctx.terms == ["MySQL", "Kubernetes"])
    }

    @Test("context correction applies the mounted rules")
    func contextCorrects() {
        let ctx = store().context(modeID: nil)
        #expect(ctx.correct("I use my sequel") == "I use MySQL")
    }

    @Test("context glossary is present with terms, nil without")
    func contextGlossary() {
        #expect(store().context(modeID: "raw").glossary?.contains("MySQL") == true)

        let empty = VocabStore(defaults: UserDefaults(suiteName: "vc-empty-\(UUID().uuidString)")!)
        #expect(empty.context(modeID: "raw").glossary == nil)
    }

    @Test("context(notebookID:) resolves global plus notebook mounts")
    func contextNotebook() {
        let name = "vc-nb-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        let s = VocabStore(defaults: d)
        let nb = UUID()
        s.upsert(VocabBook(id: "g", name: "G", terms: ["Global"]))
        s.upsert(VocabBook(id: "n", name: "N", terms: ["Notebook"]))
        s.setMounted(["g"], forKey: VocabStore.globalMountKey)
        s.setMounted(["n"], forKey: VocabStore.notebookMountKey(nb))
        #expect(s.context(notebookID: nb).terms == ["Global", "Notebook"])
        #expect(s.context(notebookID: UUID()).terms == ["Global"])
    }
}
