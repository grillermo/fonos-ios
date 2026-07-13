import Foundation

// MARK: - LLMError

/// Unified error type for LLM operations.
enum LLMError: LocalizedError, Equatable {
    case authenticationFailed
    case networkUnavailable
    case timeout
    case parseError
    case serverError(statusCode: Int)
    case notConfigured
    case requestFailed
    case emptyResponse
    case consentRequired(String)
    case insecureEndpoint

    var errorDescription: String? {
        switch self {
        case .authenticationFailed:
            "Authentication failed — check your API key."
        case .networkUnavailable:
            "Network unavailable. Check your connection."
        case .timeout:
            "Request timed out. Check your network connection."
        case .parseError:
            "Failed to parse the LLM response."
        case .serverError(let code):
            "Server error (HTTP \(code))."
        case .notConfigured:
            "LLM provider not configured."
        case .requestFailed:
            "LLM request failed."
        case .emptyResponse:
            "The LLM returned an empty response."
        case .consentRequired(let destination):
            "Permission is required before sending text to \(destination). Review this model under Settings → Models."
        case .insecureEndpoint:
            "Public AI endpoints must use HTTPS. HTTP is allowed only for a local server on this device or LAN."
        }
    }
}

// MARK: - Workflow request configuration

/// Immutable request parameters compiled from an `llm` workflow widget.
///
/// Defaults and prompt assembly intentionally mirror fonos-core's
/// `workflow::llm_step::LlmProps`: `{text}` is the default user template,
/// temperature is `0.1`, max tokens is `4096`, and `auto` preserves the input
/// language. The engine builds this value before the first await so edits to a
/// widget cannot change an in-flight run.
struct LLMRequestConfiguration: Equatable, Sendable {
    let systemPrompt: String?
    let userTemplate: String
    let temperature: Double
    let maxTokens: Int
    let outputLanguage: String
    let translateTarget: String

    init(
        systemPrompt: String? = nil,
        userTemplate: String = "{text}",
        temperature: Double = 0.1,
        maxTokens: Int = 4096,
        outputLanguage: String = "auto",
        translateTarget: String = "English",
        glossary: String? = nil
    ) {
        switch (systemPrompt, glossary) {
        case (.some(let system), .some(let block)):
            self.systemPrompt = system + block
        case (.none, .some(let block)):
            self.systemPrompt = block.trimmingCharacters(in: .whitespacesAndNewlines)
        case (.some(let system), .none):
            self.systemPrompt = system
        case (.none, .none):
            self.systemPrompt = nil
        }
        self.userTemplate = userTemplate
        self.temperature = temperature
        self.maxTokens = maxTokens
        self.outputLanguage = outputLanguage
        self.translateTarget = translateTarget
    }

    /// Desktop-compatible user-message construction.
    func userMessage(for text: String) -> String {
        var template = userTemplate
        if template.contains("{target_lang}") {
            let target = translateTarget.isEmpty ? "English" : translateTarget
            template = template.replacingOccurrences(of: "{target_lang}", with: target)
        }
        if !outputLanguage.isEmpty,
           outputLanguage != "auto",
           !template.contains("{target_lang}") {
            template += "\n\nIMPORTANT: Output in \(outputLanguage)."
        }
        return template.replacingOccurrences(of: "{text}", with: text)
    }

    func messages(for text: String) -> [[String: String]] {
        var result: [[String: String]] = []
        if let systemPrompt {
            result.append(["role": "system", "content": systemPrompt])
        }
        result.append(["role": "user", "content": userMessage(for: text)])
        return result
    }
}

// MARK: - LLMService

/// Sends text to an OpenAI-compatible chat completions endpoint for post-processing.
final class LLMService: Sendable {

    private let session: URLSession
    private let apiKey: String
    private let modelID: String
    private let baseURL: String
    private let provider: String
    private let consentAuthorizer: RemoteAIConsentStore.Authorizer

    /// Default temperature used by the legacy mode API.
    private let defaultTemperature: Double = 0.3

    init(session: URLSession = .shared,
         apiKey: String,
         modelID: String = "gpt-4o",
         baseURL: String = "https://api.openai.com",
         provider: String = "openai",
         consentAuthorizer: @escaping RemoteAIConsentStore.Authorizer = RemoteAIConsentStore.liveAuthorizer) {
        self.session = session
        self.apiKey = apiKey
        self.modelID = modelID
        self.baseURL = baseURL
        self.provider = provider
        self.consentAuthorizer = consentAuthorizer
    }

    /// Process text through the given mode using an LLM.
    /// - Parameters:
    ///   - text: The raw transcript to process.
    ///   - mode: The processing mode that defines the prompt.
    ///   - glossary: Optional vocab glossary block appended to the system prompt.
    /// - Returns: The processed text from the LLM.
    /// - Throws: `LLMError` on failure (caller can fall back to raw transcript).
    func process(text: String, mode: Mode, glossary: String? = nil) async throws -> String {
        let configuration = LLMRequestConfiguration(
            systemPrompt: mode.systemPrompt,
            userTemplate: mode.userTemplate,
            temperature: temperatureForMode(mode),
            maxTokens: maxTokensForMode(mode),
            glossary: glossary
        )
        return try await process(text: text, configuration: configuration)
    }

    /// Process text using parameters compiled from a workflow `llm` widget.
    /// The response is trimmed and an empty completion is rejected.
    func process(text: String, configuration: LLMRequestConfiguration) async throws -> String {
        try Task.checkCancellation()
        let consentURL = baseURL.isEmpty ? providerDefaultBaseURL : baseURL
        guard RemoteAITransportPolicy.allows(consentURL) else {
            throw LLMError.insecureEndpoint
        }
        guard consentAuthorizer(provider, consentURL) else {
            let destination = RemoteAIEndpointIdentity(provider: provider, baseURL: consentURL)
                .map { "\($0.providerDisplayName) at \($0.origin)" }
                ?? "the configured AI endpoint"
            throw LLMError.consentRequired(destination)
        }
        let messages = configuration.messages(for: text)
        switch provider.lowercased() {
        case "anthropic":
            return try await performAnthropic(
                messages: messages,
                temperature: configuration.temperature,
                maxTokens: configuration.maxTokens
            )
        case "google":
            return try await performGoogle(
                messages: messages,
                temperature: configuration.temperature,
                maxTokens: configuration.maxTokens
            )
        default:
            break
        }
        let requestBody = buildRequestBody(
            messages: messages,
            temperature: configuration.temperature,
            maxTokens: configuration.maxTokens,
            modelID: modelID
        )
        return try await perform(requestBody: requestBody)
    }

    // MARK: - Private helpers

    private func buildRequestBody(
        messages: [[String: String]],
        temperature: Double,
        maxTokens: Int,
        modelID: String
    ) -> [String: Any] {
        var body: [String: Any] = [
            "model": modelID,
            "messages": messages
        ]

        if !shouldOmitTemperature(modelID: modelID) {
            body["temperature"] = temperature
        }
        if isOpenAIProvider {
            body["max_completion_tokens"] = maxTokens
        } else {
            body["max_tokens"] = maxTokens
        }

        return body
    }

    private var isOpenAIProvider: Bool {
        provider.lowercased() == "openai" || baseURL.contains("api.openai.com")
    }

    private var providerDefaultBaseURL: String {
        switch provider.lowercased() {
        case "omlx": return "http://localhost:8000"
        case "ollama": return "http://localhost:11434"
        case "openrouter": return "https://openrouter.ai/api/v1"
        case "anthropic": return "https://api.anthropic.com"
        case "google": return "https://generativelanguage.googleapis.com"
        default: return "https://api.openai.com"
        }
    }

    private func shouldOmitTemperature(modelID: String) -> Bool {
        guard isOpenAIProvider else { return false }
        let model = modelID.lowercased()
        return model.hasPrefix("o1")
            || model.hasPrefix("o3")
            || model.hasPrefix("o4")
            || model.contains("-nano")
    }

    private func perform(requestBody: [String: Any]) async throws -> String {
        let effectiveBase = baseURL.isEmpty ? providerDefaultBaseURL : baseURL
        let trimmedBase = effectiveBase.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let endpoint = trimmedBase.hasSuffix("/v1")
            ? "\(trimmedBase)/chat/completions"
            : "\(trimmedBase)/v1/chat/completions"
        guard let url = URL(string: endpoint) else {
            throw LLMError.networkUnavailable
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        if !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: requestBody)
        } catch {
            throw LLMError.requestFailed
        }

        return try await execute(request: request, parser: parseOpenAIResponse)
    }

    private func performAnthropic(
        messages: [[String: String]],
        temperature: Double,
        maxTokens: Int
    ) async throws -> String {
        let system = messages.first(where: { $0["role"] == "system" })?["content"] ?? ""
        let userMessages = messages.filter { $0["role"] != "system" }
        let body: [String: Any] = [
            "model": modelID,
            "max_tokens": maxTokens,
            "system": system,
            "messages": userMessages,
            "temperature": temperature
        ]
        let base = (baseURL.isEmpty ? providerDefaultBaseURL : baseURL)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let endpoint = base.hasSuffix("/v1") ? "\(base)/messages" : "\(base)/v1/messages"
        guard let url = URL(string: endpoint) else { throw LLMError.networkUnavailable }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try encodeJSON(body)
        return try await execute(request: request, parser: parseAnthropicResponse)
    }

    private func performGoogle(
        messages: [[String: String]],
        temperature: Double,
        maxTokens: Int
    ) async throws -> String {
        let system = messages.first(where: { $0["role"] == "system" })?["content"] ?? ""
        let contents: [[String: Any]] = messages.compactMap { message in
            guard message["role"] != "system" else { return nil }
            let role = message["role"] == "assistant" ? "model" : "user"
            return ["role": role, "parts": [["text": message["content"] ?? ""]]]
        }
        let body: [String: Any] = [
            "systemInstruction": ["parts": [["text": system]]],
            "contents": contents,
            "generationConfig": [
                "temperature": temperature,
                "maxOutputTokens": maxTokens
            ]
        ]
        let base = (baseURL.isEmpty ? providerDefaultBaseURL : baseURL)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let escapedModel = modelID.addingPercentEncoding(
            withAllowedCharacters: .urlPathAllowed
        ) ?? modelID
        let endpoint = "\(base)/v1beta/models/\(escapedModel):generateContent"
        guard var components = URLComponents(string: endpoint) else {
            throw LLMError.networkUnavailable
        }
        components.queryItems = [URLQueryItem(name: "key", value: apiKey)]
        guard let url = components.url else { throw LLMError.networkUnavailable }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try encodeJSON(body)
        return try await execute(request: request, parser: parseGoogleResponse)
    }

    private func encodeJSON(_ value: [String: Any]) throws -> Data {
        do {
            return try JSONSerialization.data(withJSONObject: value)
        } catch {
            throw LLMError.requestFailed
        }
    }

    private func execute(
        request: URLRequest,
        parser: (Data) throws -> String
    ) async throws -> String {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let urlError as URLError {
            if urlError.code == .cancelled || Task.isCancelled {
                throw CancellationError()
            }
            switch urlError.code {
            case .timedOut:
                throw LLMError.timeout
            case .notConnectedToInternet, .networkConnectionLost:
                throw LLMError.networkUnavailable
            default:
                throw LLMError.networkUnavailable
            }
        }
        try Task.checkCancellation()

        guard let httpResponse = response as? HTTPURLResponse else {
            throw LLMError.parseError
        }
        switch httpResponse.statusCode {
        case 200..<300: break
        case 401: throw LLMError.authenticationFailed
        default: throw LLMError.serverError(statusCode: httpResponse.statusCode)
        }
        return try parser(data)
    }

    private func maxTokensForMode(_ mode: Mode) -> Int {
        if case .custom(_, _, _, let maxTokens) = mode {
            return maxTokens
        }
        return 1024
    }

    private func temperatureForMode(_ mode: Mode) -> Double {
        if case .custom(_, _, let temp, _) = mode {
            return temp
        }
        return defaultTemperature
    }

    private func parseOpenAIResponse(data: Data) throws -> String {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let firstChoice = choices.first,
              let message = firstChoice["message"] as? [String: Any],
              let content = message["content"] as? String else {
            throw LLMError.parseError
        }
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw LLMError.emptyResponse }
        return trimmed
    }

    private func parseAnthropicResponse(_ data: Data) throws -> String {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = json["content"] as? [[String: Any]],
              let text = content.compactMap({ $0["text"] as? String }).first else {
            throw LLMError.parseError
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw LLMError.emptyResponse }
        return trimmed
    }

    private func parseGoogleResponse(_ data: Data) throws -> String {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let candidates = json["candidates"] as? [[String: Any]],
              let content = candidates.first?["content"] as? [String: Any],
              let parts = content["parts"] as? [[String: Any]],
              let text = parts.compactMap({ $0["text"] as? String }).first else {
            throw LLMError.parseError
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw LLMError.emptyResponse }
        return trimmed
    }
}

// MARK: - Note Pipeline

extension LLMService {
    /// Note-pipeline entry point. Bypasses the `Mode` enum (which is for Dictation)
    /// and uses the per-notebook NotebookLLMConfig directly.
    ///
    /// Output-language injection: when `config.outputLanguage` is non-nil, prepends
    /// `Always respond in {lang}.` followed by a blank line to the system prompt.
    /// Prefix placement gives the strongest steering for chat models.
    func processNote(text: String, config: NotebookLLMConfig) async throws -> String {
        let composedSystem = Self.composeSystemPrompt(
            user: config.systemPrompt,
            outputLanguage: config.outputLanguage
        )
        let modelToUse = config.modelOverride ?? modelID
        let service = modelToUse == modelID
            ? self
            : LLMService(
                session: session,
                apiKey: apiKey,
                modelID: modelToUse,
                baseURL: baseURL,
                provider: provider,
                consentAuthorizer: consentAuthorizer
            )
        return try await service.process(
            text: text,
            configuration: LLMRequestConfiguration(
                systemPrompt: composedSystem,
                userTemplate: "{text}",
                temperature: 0.3,
                maxTokens: 1024
            )
        )
    }

    static func composeSystemPrompt(user: String, outputLanguage: String?) -> String {
        guard let lang = outputLanguage, !lang.isEmpty else { return user }
        return "Always respond in \(lang).\n\n\(user)"
    }
}
