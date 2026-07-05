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

    @Test("no configured profile falls back to AppleSTT")
    func emptyProfileFallsBackToApple() {
        let provider = STTResolver.resolve(config: makeConfig(profile: nil, sttProfile: ""))
        #expect(provider is AppleSTT)
    }

    @Test("dangling profile reference falls back to AppleSTT")
    func danglingProfileFallsBackToApple() {
        let provider = STTResolver.resolve(config: makeConfig(profile: nil, sttProfile: "ghost-profile"))
        #expect(provider is AppleSTT)
    }

    @Test("profile without STT capability and non-fonos provider falls back to AppleSTT")
    func llmOnlyProfileFallsBackToApple() {
        let profile = ModelProfile(id: "llm-1", name: "GPT", provider: "custom",
                                   modelID: "gpt-4o", baseURL: "https://example.com",
                                   capabilities: ["llm"])
        let provider = STTResolver.resolve(config: makeConfig(profile: profile, sttProfile: "llm-1"))
        #expect(provider is AppleSTT)
    }
}
