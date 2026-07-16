import Foundation
import os.log

final class ChatSTT: STTProvider, @unchecked Sendable {
    private let session: URLSession
    private let apiKey: String
    private let baseURL: String
    private let modelID: String
    private let provider: String
    private let consentAuthorizer: RemoteAIConsentStore.Authorizer

    init(
        session: URLSession = .shared,
        apiKey: String,
        baseURL: String,
        modelID: String,
        provider: String = "custom",
        consentAuthorizer: @escaping RemoteAIConsentStore.Authorizer = RemoteAIConsentStore.liveAuthorizer
    ) {
        self.session = session
        self.apiKey = apiKey
        self.baseURL = baseURL
        self.modelID = modelID
        self.provider = provider
        self.consentAuthorizer = consentAuthorizer
    }

    func transcribe(audioData: Data, language: String?) async throws -> String {
        try await transcribe(
            audioData: audioData,
            language: language,
            vocabulary: [],
            promptHint: ""
        )
    }

    func transcribe(
        audioData: Data,
        language: String?,
        vocabulary: [String],
        promptHint: String
    ) async throws -> String {
        try Task.checkCancellation()
        try validateRemoteAccess()
        let request = try makeRequest(
            audioData: audioData,
            language: language,
            vocabulary: vocabulary
        )
        let (data, response) = try await send(request)
        try Task.checkCancellation()
        try validate(response: response, data: data)
        return try parseTranscript(from: data)
    }

    private func validateRemoteAccess() throws {
        guard RemoteAITransportPolicy.allows(baseURL) else {
            throw STTError.insecureEndpoint
        }
        guard consentAuthorizer(provider, baseURL) else {
            throw STTError.consentRequired(Self.consentDestination(provider: provider, baseURL: baseURL))
        }
    }

    private func makeRequest(audioData: Data, language: String?, vocabulary: [String]) throws -> URLRequest {
        let url = try endpointURL()
        let body = requestBody(audioData: audioData, language: language, vocabulary: vocabulary)

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        } catch {
            throw STTError.badRequest
        }
        return request
    }

    private func endpointURL() throws -> URL {
        let trimmedBase = baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !trimmedBase.isEmpty,
              !modelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw STTError.badRequest
        }
        let endpoint: String
        if trimmedBase.hasSuffix("/chat/completions") {
            endpoint = trimmedBase
        } else if trimmedBase.hasSuffix("/v1") {
            endpoint = "\(trimmedBase)/chat/completions"
        } else {
            endpoint = "\(trimmedBase)/v1/chat/completions"
        }
        guard let url = URL(string: endpoint) else {
            throw STTError.badRequest
        }
        return url
    }

    private func requestBody(audioData: Data, language: String?, vocabulary: [String]) -> [String: Any] {
        let normalizedLanguage = STTLanguageCode.normalized(language)
        let languageHint = normalizedLanguage.map {
            " The audio is in language code '\($0)'."
        } ?? ""
        let vocabularyHint = vocabulary.isEmpty
            ? ""
            : " Domain vocabulary (prefer these exact spellings): \(vocabulary.joined(separator: ", "))."
        let instruction = "Transcribe this audio exactly as spoken. "
            + "Output only the transcript text, nothing else."
            + languageHint
            + vocabularyHint
        let body: [String: Any] = [
            "model": modelID,
            "messages": [[
                "role": "user",
                "content": [
                    ["type": "text", "text": instruction],
                    [
                        "type": "input_audio",
                        "input_audio": [
                            "data": audioData.base64EncodedString(),
                            "format": "wav"
                        ]
                    ]
                ]
            ]],
            "temperature": 0.0,
            "max_tokens": 4096
        ]
        return body
    }

    private func send(_ request: URLRequest) async throws -> (Data, URLResponse) {
        do {
            return try await session.data(for: request)
        } catch {
            if error is CancellationError || Task.isCancelled {
                throw CancellationError()
            }
            if let urlError = error as? URLError {
                switch urlError.code {
                case .cancelled: throw CancellationError()
                case .timedOut: throw STTError.timeout
                case .notConnectedToInternet, .networkConnectionLost:
                    throw STTError.networkUnavailable
                default:
                    throw STTError.recognizerError(urlError.localizedDescription)
                }
            }
            throw STTError.recognizerError(error.localizedDescription)
        }
    }

    private func validate(response: URLResponse, data: Data) throws {
        guard let httpResponse = response as? HTTPURLResponse else {
            throw STTError.parseError
        }
        switch httpResponse.statusCode {
        case 200 ... 299:
            break
        case 401, 403:
            throw STTError.authenticationFailed
        case 400:
            throw STTError.badRequest
        default:
            let responseBody = String(data: data, encoding: .utf8) ?? ""
            throw STTError.recognizerError(
                "Server returned HTTP \(httpResponse.statusCode): \(responseBody.prefix(200))"
            )
        }
    }

    private func parseTranscript(from data: Data) throws -> String {
        guard
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let choices = json["choices"] as? [[String: Any]],
            let message = choices.first?["message"] as? [String: Any],
            let content = message["content"] as? String
        else {
            throw STTError.parseError
        }
        let transcript = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !transcript.isEmpty else { throw STTError.noTranscript }
        return transcript
    }

    private static func consentDestination(provider: String, baseURL: String) -> String {
        RemoteAIEndpointIdentity(provider: provider, baseURL: baseURL)
            .map { "\($0.providerDisplayName) at \($0.origin)" }
            ?? "the configured speech endpoint"
    }
}

// MARK: - STTError

/// Unified error type for all STT providers.
