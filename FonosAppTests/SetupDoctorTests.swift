// P1-3 (docs/ROADMAP.md): Setup Doctor — one diagnostics page for the opaque
// iOS failure surface. These tests cover the pure logic: config lint
// (dangling profile refs, dangling vocab mounts), endpoint extraction, and
// reachability probing (URLProtocol-mocked).
//
// Run: xcodebuild test -scheme FonosApp -only-testing:FonosAppTests/SetupDoctorTests

import Testing
import Foundation
@testable import FonosApp

private func freshStore() -> VocabStore {
    let name = "doctor-tests-\(UUID().uuidString)"
    let d = UserDefaults(suiteName: name)!
    d.removePersistentDomain(forName: name)
    return VocabStore(defaults: d)
}

private func configWithProfiles() -> AppConfig {
    var config = AppConfig()
    config.modelProfiles = [
        ModelProfile(id: "stt1", name: "ASR", provider: "omlx",
                     modelID: "qwen-asr", baseURL: "http://192.168.1.5:8000",
                     capabilities: ["stt"]),
        ModelProfile(id: "llm1", name: "Chat", provider: "openai",
                     modelID: "gpt-4o", baseURL: "", capabilities: ["llm"]),
    ]
    return config
}

struct SetupDoctorTests {

    // MARK: - Config lint

    @Test("clean config produces no lint issues")
    func cleanConfigNoIssues() {
        var config = configWithProfiles()
        config.sttProfile = "stt1"
        config.llmProfile = "llm1"
        let issues = SetupDoctor.lintConfig(config, vocabStore: freshStore())
        #expect(issues.isEmpty)
    }

    @Test("dangling STT profile reference is reported")
    func danglingSTTProfile() {
        var config = configWithProfiles()
        config.sttProfile = "ghost"
        let issues = SetupDoctor.lintConfig(config, vocabStore: freshStore())
        #expect(issues.count == 1)
        #expect(issues.first?.contains("ghost") == true)
    }

    @Test("dangling LLM profile reference is reported")
    func danglingLLMProfile() {
        var config = configWithProfiles()
        config.llmProfile = "phantom"
        let issues = SetupDoctor.lintConfig(config, vocabStore: freshStore())
        #expect(issues.count == 1)
        #expect(issues.first?.contains("phantom") == true)
    }

    @Test("vocab mount referencing a deleted book is reported")
    func danglingVocabMount() {
        let store = freshStore()
        store.setMounted(["missing-book"], forKey: VocabStore.globalMountKey)
        let issues = SetupDoctor.lintConfig(AppConfig(), vocabStore: store)
        #expect(issues.count == 1)
        #expect(issues.first?.contains("missing-book") == true)
    }

    // MARK: - Endpoint extraction

    @Test("endpoints come from referenced profiles with non-empty base URLs, deduplicated")
    func endpointExtraction() {
        var config = configWithProfiles()
        config.sttProfile = "stt1"
        config.llmProfile = "llm1" // empty baseURL → excluded
        let urls = SetupDoctor.endpointsToCheck(config: config)
        #expect(urls.map(\.absoluteString) == ["http://192.168.1.5:8000"])
    }

    @Test("no configured profiles yields no endpoints")
    func noEndpoints() {
        #expect(SetupDoctor.endpointsToCheck(config: AppConfig()).isEmpty)
    }

    @Test("two profiles sharing one endpoint yield a single check")
    func endpointDedup() {
        var config = configWithProfiles()
        config.modelProfiles[1].baseURL = "http://192.168.1.5:8000"
        config.sttProfile = "stt1"
        config.llmProfile = "llm1"
        let urls = SetupDoctor.endpointsToCheck(config: config)
        #expect(urls.count == 1)
    }
}

// MARK: - Reachability

private final class ReachableURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}
    override func startLoading() {
        let resp = HTTPURLResponse(url: request.url!, statusCode: 404,
                                   httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data())
        client?.urlProtocolDidFinishLoading(self)
    }
}

private final class UnreachableURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}
    override func startLoading() {
        client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
    }
}

struct SetupDoctorReachabilityTests {

    private func session(_ proto: AnyClass) -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [proto]
        return URLSession(configuration: config)
    }

    @Test("any HTTP response counts as reachable (even 404)")
    func httpResponseIsReachable() async {
        let reachable = await SetupDoctor.isReachable(
            URL(string: "http://192.168.1.5:8000")!,
            session: session(ReachableURLProtocol.self))
        #expect(reachable)
    }

    @Test("connection failure counts as unreachable")
    func connectionFailureIsUnreachable() async {
        let reachable = await SetupDoctor.isReachable(
            URL(string: "http://192.168.1.5:8000")!,
            session: session(UnreachableURLProtocol.self))
        #expect(!reachable)
    }
}
