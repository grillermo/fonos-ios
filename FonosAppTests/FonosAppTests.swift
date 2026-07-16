import Testing
import Foundation
@testable import FonosApp

/// Network-service tests exercise request construction and error mapping with
/// intercepted URL sessions. Consent itself is covered separately; these
/// factories make the test authorization explicit instead of mutating the
/// simulator's real UserDefaults permission store.
func authorizedLLMService(
    session: URLSession = .shared,
    apiKey: String,
    modelID: String = "gpt-4o",
    baseURL: String = "https://api.openai.com",
    provider: String = "openai"
) -> LLMService {
    LLMService(
        session: session,
        apiKey: apiKey,
        modelID: modelID,
        baseURL: baseURL,
        provider: provider,
        consentAuthorizer: RemoteAIConsentStore.allowAll
    )
}

/// Test-side bridge from legacy fixture values into the workflow request
/// contract. Product code never accepts `Mode`; migrated recipes carry these
/// same values in their LLM widget properties.
func workflowLLMConfiguration(
    for mode: Mode,
    glossary: String? = nil
) -> LLMRequestConfiguration {
    let definition = WorkflowCanonicalLLM.definition(forLegacyMode: mode)
    return LLMRequestConfiguration(
        systemPrompt: definition.system,
        userTemplate: definition.userTemplate,
        temperature: definition.temperature,
        maxTokens: Int(definition.maxTokens),
        glossary: glossary
    )
}

func authorizedWhisperSTT(
    session: URLSession = .shared,
    apiKey: String,
    baseURL: String = "https://api.openai.com",
    modelID: String = "whisper-1",
    provider: String = "openai"
) -> WhisperSTT {
    WhisperSTT(
        session: session,
        apiKey: apiKey,
        baseURL: baseURL,
        modelID: modelID,
        provider: provider,
        consentAuthorizer: RemoteAIConsentStore.allowAll
    )
}

func authorizedChatSTT(
    session: URLSession = .shared,
    apiKey: String,
    baseURL: String,
    modelID: String,
    provider: String = "custom"
) -> ChatSTT {
    ChatSTT(
        session: session,
        apiKey: apiKey,
        baseURL: baseURL,
        modelID: modelID,
        provider: provider,
        consentAuthorizer: RemoteAIConsentStore.allowAll
    )
}

func authorizedFonosSTT(
    session: URLSession = .shared,
    serverURL: URL = URL(string: "http://localhost:8000")!
) -> FonosSTT {
    FonosSTT(
        session: session,
        serverURL: serverURL,
        consentAuthorizer: RemoteAIConsentStore.allowAll
    )
}

/// Scaffold test suite — individual test classes go in separate files.
struct FonosAppTests {

    // P0-2 (docs/ROADMAP.md): the fonos:// URL scheme must be registered so
    // widget taps and Siri App Intents can open the app. Tests are hosted in
    // FonosApp.app, so Bundle.main is the app bundle.
    @Test func fonosURLSchemeIsRegistered() {
        let urlTypes = Bundle.main.object(forInfoDictionaryKey: "CFBundleURLTypes") as? [[String: Any]] ?? []
        let schemes = urlTypes.flatMap { $0["CFBundleURLSchemes"] as? [String] ?? [] }
        #expect(schemes.contains("fonos"))
    }

    @Test func appConfigDefaultValues() {
        let config = WorkflowMigration.migrated(AppConfig())
        #expect(config.sttProvider == "apple")
        #expect(config.activeVoiceWorkflow?.id == "wf.dictation")
        #expect(config.recordMode == .tap)
    }

    @Test func modeBuiltInCount() {
        #expect(Mode.builtInModes.count == 5)
    }

    @Test func rawModeDoesNotRequireLLM() {
        let raw = Mode.builtInModes.first { $0.id == "raw" }
        #expect(raw != nil)
        #expect(raw?.requiresLLM == false)
    }

    @Test func llmModesRequireLLM() {
        let llmModes = Mode.builtInModes.filter { $0.id != "raw" }
        #expect(llmModes.allSatisfy { $0.requiresLLM })
    }

    @Test func removingModelClearsDefaultsAndWorkflowReferences() {
        let profile = ModelProfile(
            id: "shared-model",
            name: "Shared Model",
            provider: "openai",
            modelID: "model",
            capabilities: ["stt", "llm"]
        )
        var config = WorkflowMigration.migrated(AppConfig())
        config.modelProfiles = [profile]
        config.sttProfile = profile.id
        config.llmProfile = profile.id
        var sttWidget = config.workflowCatalog.widget(id: "stt.default")!
        if case .object(var props) = sttWidget.props {
            props["model_profile"] = .string(profile.id)
            sttWidget.props = .object(props)
        }
        config.widgets.append(sttWidget)

        config.removeModelProfile(id: profile.id)

        #expect(config.modelProfiles.isEmpty)
        #expect(config.sttProfile.isEmpty)
        #expect(config.llmProfile.isEmpty)
        #expect(config.widgets.allSatisfy {
            $0.props["model_profile"]?.stringValue != profile.id
        })
    }

    @Test func workflowWithoutOverrideUsesAppDefaults() throws {
        let stt = ModelProfile(
            id: "default-stt",
            name: "Default STT",
            provider: "openai",
            modelID: "whisper",
            capabilities: ["stt"]
        )
        let llm = ModelProfile(
            id: "default-llm",
            name: "Default LLM",
            provider: "openai",
            modelID: "gpt",
            capabilities: ["llm"]
        )
        var config = WorkflowMigration.migrated(AppConfig())
        config.modelProfiles = [stt, llm]
        config.sttProfile = stt.id
        config.llmProfile = llm.id
        let workflow = try #require(config.workflowCatalog.workflow(id: "wf.voice.polish"))
        let explicitProfileIDs = workflow.processors.map {
            config.workflowCatalog.widget(id: $0)?.props["model_profile"]?.stringValue
        }
        #expect(explicitProfileIDs.allSatisfy { ($0 ?? "").isEmpty })
        #expect(try VoiceWorkflowOperationalValidator.validateMicrophone(
            definition: workflow,
            catalog: config.workflowCatalog,
            config: config
        ).sourceKind == .microphone)
    }
}

// P1-4 (docs/ROADMAP.md): EN/zh-Hans localization. The String Catalog must
// compile into a zh-Hans lproj inside the app bundle with real translations.
struct LocalizationTests {

    private func zhHansBundle() -> Bundle? {
        Bundle.main.path(forResource: "zh-Hans", ofType: "lproj").flatMap(Bundle.init(path:))
    }

    @Test("zh-Hans localization bundle ships in the app")
    func zhHansBundleExists() {
        #expect(zhHansBundle() != nil)
    }

    @Test("core UI strings are translated to Simplified Chinese")
    func coreStringsTranslated() throws {
        let bundle = try #require(zhHansBundle())
        let cases: [(key: String, expected: String)] = [
            ("History", "历史"),
            ("Notes", "笔记"),
            ("Settings", "设置"),
            ("Tap to dictate", "点按开始听写"),
            ("Save Correction", "保存纠正"),
            ("Import Scenario", "导入场景"),
            ("Voice flow", "语音处理流程"),
            ("Flow complete", "处理流程已完成"),
            ("Transcript ready", "转写文本已就绪"),
        ]
        for (key, expected) in cases {
            let value = bundle.localizedString(forKey: key, value: nil, table: nil)
            #expect(value == expected, "\(key) → \(value)")
        }
    }

    @Test("app declares en and zh-Hans localizations")
    func bundleLocalizationsDeclared() {
        let declared = Bundle.main.object(forInfoDictionaryKey: "CFBundleLocalizations") as? [String] ?? []
        #expect(declared.contains("en"))
        #expect(declared.contains("zh-Hans"))
    }
}

struct RemoteAIConsentTests {
    private func freshDefaults() -> UserDefaults {
        let name = "remote-ai-consent-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    @Test("consent is scoped to provider and endpoint and can be withdrawn")
    func endpointScopedConsent() {
        let defaults = freshDefaults()
        let profile = ModelProfile(
            id: "remote",
            name: "Remote",
            provider: "openai",
            modelID: "gpt",
            baseURL: "https://api.openai.com/v1",
            capabilities: ["llm"]
        )

        #expect(!RemoteAIConsentStore.isAuthorized(for: profile, defaults: defaults))
        RemoteAIConsentStore.grant(for: profile, defaults: defaults)
        #expect(RemoteAIConsentStore.isAuthorized(for: profile, defaults: defaults))
        #expect(!RemoteAIConsentStore.isAuthorized(
            provider: "anthropic",
            baseURL: "https://api.openai.com",
            defaults: defaults
        ))

        RemoteAIConsentStore.revokeAll(defaults: defaults)
        #expect(!RemoteAIConsentStore.isAuthorized(for: profile, defaults: defaults))
    }

    @Test("transport policy classifies IPv4 LAN and public addresses")
    func transportPolicy() {
        #expect(RemoteAITransportPolicy.allows("https://api.openai.com"))
        for url in [
            "http://localhost:8000",
            "http://10.0.0.1",
            "http://127.0.0.1",
            "http://169.254.20.3",
            "http://172.16.0.1",
            "http://172.31.255.255",
            "http://192.168.1.42:8000",
            "http://model-server.local",
        ] {
            #expect(RemoteAITransportPolicy.allows(url), "Expected local HTTP: \(url)")
        }
        for url in [
            "http://8.8.8.8",
            "http://172.15.255.255",
            "http://172.32.0.1",
            "http://192.169.1.1",
            "http://api.openai.com",
        ] {
            #expect(!RemoteAITransportPolicy.allows(url), "Expected public HTTP rejection: \(url)")
        }
    }

    @Test("transport policy accepts only local IPv6 literals over HTTP")
    func ipv6TransportPolicy() {
        for url in [
            "http://[::1]:11434",
            "http://[fc00::1]",
            "http://[fd12:3456:789a::1]",
            "http://[fe80::1]",
            "http://[febf:ffff::1]",
        ] {
            #expect(RemoteAITransportPolicy.allows(url), "Expected local IPv6 HTTP: \(url)")
        }
        for url in [
            "http://[fec0::1]",
            "http://[2001:db8::1]",
            "http://[2606:4700:4700::1111]",
        ] {
            #expect(!RemoteAITransportPolicy.allows(url), "Expected public IPv6 rejection: \(url)")
        }
    }

    @Test("IPv6-looking domain names are not treated as IPv6 literals")
    func ipv6PrefixDomainRegression() {
        for url in [
            "http://fd.example.com",
            "http://fc00.example.com",
            "http://fe80.example.com",
            "http://feb-model.example.com",
            "http://192.168.1.42.example.com",
        ] {
            #expect(!RemoteAITransportPolicy.allows(url), "Expected domain rejection: \(url)")
        }
    }

    @Test("LLM network boundary blocks text before URLSession without permission")
    func llmRequiresConsent() async {
        let service = LLMService(
            apiKey: "secret",
            consentAuthorizer: { _, _ in false }
        )
        await #expect(throws: LLMError.self) {
            _ = try await service.process(
                text: "private transcript",
                configuration: workflowLLMConfiguration(for: .polish)
            )
        }
        do {
            _ = try await service.process(
                text: "private transcript",
                configuration: workflowLLMConfiguration(for: .polish)
            )
            Issue.record("Expected remote-AI consent to be required")
        } catch let error as LLMError {
            guard case .consentRequired = error else {
                Issue.record("Expected consentRequired, got \(error)")
                return
            }
        } catch {
            Issue.record("Expected LLMError, got \(error)")
        }
    }

    @Test("STT resolver blocks audio from imported profiles without permission")
    func importedSTTProfileRequiresConsent() async {
        let endpoint = "https://consent-\(UUID().uuidString.lowercased()).example"
        var importedConfig = AppConfig()
        importedConfig.sttProfile = "imported-stt"
        importedConfig.modelProfiles = [ModelProfile(
            id: "imported-stt",
            name: "Imported STT",
            provider: "custom",
            modelID: "whisper",
            baseURL: endpoint,
            capabilities: ["stt"]
        )]

        let provider = STTResolver.resolve(config: importedConfig)
        do {
            _ = try await provider.transcribe(audioData: Data([0, 1, 2]), language: "en")
            Issue.record("Expected remote-AI consent to be required")
        } catch let error as STTError {
            guard case .consentRequired = error else {
                Issue.record("Expected consentRequired, got \(error)")
                return
            }
        } catch {
            Issue.record("Expected STTError, got \(error)")
        }
    }
}
