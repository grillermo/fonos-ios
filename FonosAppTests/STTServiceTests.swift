// P0-5 (docs/ROADMAP.md): STT provider resolution must be shared between
// DictationViewModel and NoteViewModel — Notes previously always used AppleSTT
// regardless of the configured profile.
//
// Run: xcodebuild test -scheme FonosApp -only-testing:FonosAppTests/STTResolverTests

import Testing
import Foundation
@testable import FonosApp

private func makeConfig(profile: ModelProfile?, sttProfile: String) -> AppConfig {
    var config = AppConfig()
    config.modelProfiles = profile.map { [$0] } ?? []
    config.sttProfile = sttProfile
    return config
}

struct STTResolverTests {

    @Test("desktop language names normalize to API codes while BCP-47 passes through")
    func desktopLanguageNormalization() {
        #expect(STTLanguageCode.normalized("English") == "en")
        #expect(STTLanguageCode.normalized("Cantonese") == "yue")
        #expect(STTLanguageCode.normalized("zh-CN") == "zh-CN")
        #expect(STTLanguageCode.normalized(" auto ") == nil)
        #expect(STTLanguageCode.appleLocaleIdentifier("Chinese") == "zh-CN")
    }

    @Test("openai profile resolves to WhisperSTT")
    func openAIResolvesToWhisper() {
        let profile = ModelProfile(id: "openai-1", name: "Whisper", provider: "openai",
                                   modelID: "whisper-1", capabilities: ["stt"])
        let provider = STTResolver.resolve(config: makeConfig(profile: profile, sttProfile: "openai-1"))
        #expect(provider is WhisperSTT)
    }

    @Test("fonos profile resolves to FonosSTT")
    func fonosResolvesToFonosSTT() {
        let profile = ModelProfile(id: "fonos-1", name: "Fonos Server", provider: "fonos",
                                   modelID: "fonos-stt", baseURL: "http://192.168.1.5:9880",
                                   capabilities: ["stt"])
        let provider = STTResolver.resolve(config: makeConfig(profile: profile, sttProfile: "fonos-1"))
        #expect(provider is FonosSTT)
    }

    @Test("other provider with STT capability and base URL resolves to Whisper-compatible endpoint")
    func omlxResolvesToWhisperCompatible() {
        let profile = ModelProfile(id: "omlx-1", name: "OMLX", provider: "omlx",
                                   modelID: "whisper-large-v3", baseURL: "http://localhost:10240",
                                   capabilities: ["stt", "llm"])
        let provider = STTResolver.resolve(config: makeConfig(profile: profile, sttProfile: "omlx-1"))
        #expect(provider is WhisperSTT)
    }

    @Test("chat STT profiles resolve to multimodal ChatSTT")
    func chatProfileResolvesToChatSTT() {
        let profile = ModelProfile(
            id: "openrouter-audio",
            name: "Audio Chat",
            provider: "openrouter",
            modelID: "openai/gpt-audio-mini",
            capabilities: ["stt"],
            sttAPI: "chat"
        )
        let provider = STTResolver.resolve(
            config: makeConfig(profile: profile, sttProfile: profile.id)
        )
        #expect(provider is ChatSTT)
    }

    @Test("no configured profile falls back to AppleSTT")
    func emptyProfileFallsBackToApple() {
        let provider = STTResolver.resolve(config: makeConfig(profile: nil, sttProfile: ""))
        #expect(provider is AppleSTT)
    }

    @Test("desktop apple-speech sentinel resolves to AppleSTT")
    func appleSpeechSentinelResolvesToApple() {
        let provider = STTResolver.resolve(
            config: makeConfig(profile: nil, sttProfile: ModelProfileReference.appleSpeech)
        )
        #expect(provider is AppleSTT)
    }

    @Test("dangling profile reference fails explicitly instead of changing provider")
    func danglingProfileFailsExplicitly() async {
        let provider = STTResolver.resolve(config: makeConfig(profile: nil, sttProfile: "ghost-profile"))
        do {
            _ = try await provider.transcribe(audioData: Data(), language: nil)
            Issue.record("Expected unavailable profile error")
        } catch let error as STTError {
            guard case .profileUnavailable(let reason) = error else {
                Issue.record("Unexpected STT error: \(error)")
                return
            }
            #expect(reason.contains("ghost-profile"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test("profile without STT capability fails explicitly")
    func llmOnlyProfileFailsExplicitly() async {
        let profile = ModelProfile(id: "llm-1", name: "GPT", provider: "custom",
                                   modelID: "gpt-4o", baseURL: "https://example.com",
                                   capabilities: ["llm"])
        let provider = STTResolver.resolve(config: makeConfig(profile: profile, sttProfile: "llm-1"))
        do {
            _ = try await provider.transcribe(audioData: Data(), language: nil)
            Issue.record("Expected unavailable profile error")
        } catch let error as STTError {
            guard case .profileUnavailable = error else {
                Issue.record("Unexpected STT error: \(error)")
                return
            }
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test("model profile provider defaults mirror desktop service resolution")
    func modelProfileProviderDefaults() {
        #expect(ModelProfile(id: "o", name: "O", provider: "openai", modelID: "m")
            .effectiveBaseURL == "https://api.openai.com")
        #expect(ModelProfile(id: "r", name: "R", provider: "openrouter", modelID: "m")
            .effectiveBaseURL == "https://openrouter.ai/api/v1")
        #expect(ModelProfile(id: "a", name: "A", provider: "anthropic", modelID: "m")
            .effectiveBaseURL == "https://api.anthropic.com")
        #expect(ModelProfile(id: "g", name: "G", provider: "google", modelID: "m")
            .effectiveBaseURL == "https://generativelanguage.googleapis.com")
        let endpointProfile = ModelProfile(
            id: "e",
            name: "Endpoint",
            provider: "custom",
            modelID: "m",
            baseURL: " https://example.com/api/v1/chat/completions/ "
        )
        #expect(endpointProfile.portableBaseURL == "https://example.com/api")
        #expect(endpointProfile.effectiveBaseURL == "https://example.com/api")
        #expect(ModelProfile(
            id: "bad-api", name: "Bad", provider: "openai", modelID: "m",
            capabilities: ["stt"], sttAPI: "CHAT"
        ).effectiveSTTAPI == "whisper")
    }

    @Test("model profile canonicalizes concrete desktop-appended service routes")
    func modelProfileCanonicalizesConcreteRoutes() {
        let cases = [
            ("https://speech.example/v1/audio/transcriptions/", "https://speech.example"),
            ("https://speech.example/gateway/audio/transcriptions", "https://speech.example/gateway"),
            ("https://chat.example/api/v1/chat/completions/", "https://chat.example/api"),
            ("https://chat.example/gateway/chat/completions", "https://chat.example/gateway")
        ]

        for (endpoint, expectedBase) in cases {
            let profile = ModelProfile(
                id: endpoint,
                name: "Endpoint",
                provider: "custom",
                modelID: "model",
                baseURL: endpoint,
                capabilities: ["stt", "llm"]
            )
            #expect(profile.baseURL == expectedBase)
            #expect(profile.portableBaseURL == expectedBase)
            #expect(profile.effectiveBaseURL == expectedBase)
        }
    }

    @Test("profile references are whitespace-canonical at resolution")
    func whitespaceProfileReferenceResolves() {
        let profile = ModelProfile(
            id: "openai-1",
            name: "Whisper",
            provider: "openai",
            modelID: "whisper-1",
            capabilities: ["stt"]
        )
        let provider = STTResolver.resolve(
            config: makeConfig(profile: profile, sttProfile: "  openai-1  ")
        )
        #expect(provider is WhisperSTT)
    }
}

// MARK: - LAN-first endpoint with public fallback

private final class ProbeCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    var count: Int { lock.withLock { value } }
    func increment() { lock.withLock { value += 1 } }
}

private final class MutableBox<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: T
    init(_ value: T) { stored = value }
    var value: T {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}

private struct StubSTT: STTProvider {
    let result: Result<String, STTError>
    let calls: ProbeCounter
    func transcribe(audioData: Data, language: String?) async throws -> String {
        calls.increment()
        return try result.get()
    }
}

private let homeWiFi = LocalNetworkFingerprint.Interface(
    name: "en0",
    address: LocalNetworkFingerprint.ipv4("192.168.1.42")!,
    netmask: LocalNetworkFingerprint.ipv4("255.255.255.0")!
)
private let cafeWiFi = LocalNetworkFingerprint.Interface(
    name: "en0",
    address: LocalNetworkFingerprint.ipv4("10.0.4.17")!,
    netmask: LocalNetworkFingerprint.ipv4("255.255.255.0")!
)

struct EndpointRouterTests {
    private let lan = "http://192.168.1.3:8787"

    private func makeRouter(
        interfaces: MutableBox<[LocalNetworkFingerprint.Interface]>,
        reachable: Bool,
        probes: ProbeCounter,
        clock: MutableBox<Date> = MutableBox(Date(timeIntervalSince1970: 0))
    ) -> EndpointRouter {
        EndpointRouter(
            prober: { _, _, _ in probes.increment(); return reachable },
            networkReader: { LocalNetworkFingerprint.evaluate(host: $0, interfaces: interfaces.value) },
            now: { clock.value }
        )
    }

    @Test("off the LAN subnet the fallback is chosen with no probe at all")
    func offSubnetSkipsProbe() async {
        let probes = ProbeCounter()
        let router = makeRouter(interfaces: MutableBox([cafeWiFi]), reachable: true, probes: probes)
        #expect(await router.prefersPrimary(lan) == false)
        #expect(await router.prefersPrimary(lan) == false)
        #expect(probes.count == 0)
    }

    @Test("on the LAN subnet one probe is reused for every request")
    func probeIsCachedPerNetwork() async {
        let probes = ProbeCounter()
        let router = makeRouter(interfaces: MutableBox([homeWiFi]), reachable: true, probes: probes)
        for _ in 0 ..< 5 { #expect(await router.prefersPrimary(lan)) }
        #expect(probes.count == 1)
    }

    @Test("changing networks invalidates the cached verdict")
    func networkChangeReprobes() async {
        let probes = ProbeCounter()
        let interfaces = MutableBox([homeWiFi])
        let router = makeRouter(interfaces: interfaces, reachable: true, probes: probes)
        #expect(await router.prefersPrimary(lan))
        interfaces.value = [LocalNetworkFingerprint.Interface(
            name: "en0", address: LocalNetworkFingerprint.ipv4("192.168.1.99")!,
            netmask: homeWiFi.netmask
        )]
        #expect(await router.prefersPrimary(lan))
        #expect(probes.count == 2)
    }

    @Test("a failed request demotes the primary until the down TTL expires")
    func failureDemotesThenRecovers() async {
        let probes = ProbeCounter()
        let clock = MutableBox(Date(timeIntervalSince1970: 0))
        let router = makeRouter(interfaces: MutableBox([homeWiFi]), reachable: true,
                                probes: probes, clock: clock)
        #expect(await router.prefersPrimary(lan))
        await router.reportFailure(lan)
        #expect(await router.prefersPrimary(lan) == false)
        #expect(probes.count == 1)
        clock.value = clock.value.addingTimeInterval(router.downTTL + 1)
        #expect(await router.prefersPrimary(lan))
        #expect(probes.count == 2)
    }

    @Test("FailoverSTT retries on the fallback when the primary fails")
    func failoverSTTUsesFallback() async throws {
        let router = makeRouter(interfaces: MutableBox([homeWiFi]), reachable: true, probes: ProbeCounter())
        let primaryCalls = ProbeCounter()
        let fallbackCalls = ProbeCounter()
        let stt = FailoverSTT(
            primary: StubSTT(result: .failure(.timeout), calls: primaryCalls),
            fallback: StubSTT(result: .success("hola"), calls: fallbackCalls),
            primaryBaseURL: lan,
            router: router
        )
        #expect(try await stt.transcribe(audioData: Data(), language: nil) == "hola")
        #expect(try await stt.transcribe(audioData: Data(), language: nil) == "hola")
        // Second request skips the demoted primary entirely.
        #expect(primaryCalls.count == 1)
        #expect(fallbackCalls.count == 2)
    }

    @Test("profile with a fallback resolves to FailoverSTT; without one, unchanged")
    func resolverWrapsOnlyWithFallback() {
        let withFallback = ModelProfile(
            id: "custom-1", name: "mema", provider: "custom", modelID: "qwen",
            baseURL: lan, capabilities: ["stt"], fallbackBaseURL: "https://mema.chiq.me/"
        )
        #expect(withFallback.effectiveFallbackBaseURL == "https://mema.chiq.me")
        #expect(STTResolver.resolve(config: makeConfig(profile: withFallback, sttProfile: "custom-1"))
            is FailoverSTT)
        var same = withFallback
        same.fallbackBaseURL = lan
        #expect(same.effectiveFallbackBaseURL == nil)
        #expect(STTResolver.resolve(config: makeConfig(profile: same, sttProfile: "custom-1"))
            is WhisperSTT)
    }

    @Test("consent covers both endpoints of a profile")
    func consentCoversFallback() throws {
        let defaults = try #require(UserDefaults(suiteName: "EndpointRouterTests-\(UUID())"))
        let profile = ModelProfile(
            id: "custom-1", name: "mema", provider: "custom", modelID: "qwen",
            baseURL: lan, capabilities: ["stt"], fallbackBaseURL: "https://mema.chiq.me"
        )
        RemoteAIConsentStore.grant(provider: "custom", baseURL: lan, defaults: defaults)
        #expect(RemoteAIConsentStore.isAuthorized(for: profile, defaults: defaults) == false)
        RemoteAIConsentStore.grant(for: profile, defaults: defaults)
        #expect(RemoteAIConsentStore.isAuthorized(for: profile, defaults: defaults))
        #expect(RemoteAIConsentStore.isAuthorized(
            provider: "custom", baseURL: "https://mema.chiq.me", defaults: defaults))
    }

    @Test("scheme-less input gets http for LAN hosts and https otherwise")
    func schemeInference() {
        #expect(ModelProfileForm.withScheme("192.168.1.3:8787") == "http://192.168.1.3:8787")
        #expect(ModelProfileForm.withScheme("mema.chiq.me") == "https://mema.chiq.me")
        #expect(ModelProfileForm.withScheme("https://x.y") == "https://x.y")
    }
}
