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
