import Foundation
import os.log

final class WhisperSTT: STTProvider, @unchecked Sendable {
    private let session: URLSession
    private let apiKey: String
    private let baseURL: String
    private let modelID: String  // actual model ID to send in the request
    private let provider: String
    private let consentAuthorizer: RemoteAIConsentStore.Authorizer

    init(session: URLSession = .shared,
         apiKey: String,
         baseURL: String = "https://api.openai.com",
         modelID: String = "whisper-1",
         provider: String = "openai",
         consentAuthorizer: @escaping RemoteAIConsentStore.Authorizer = RemoteAIConsentStore.liveAuthorizer) {
        self.session = session
        self.apiKey = apiKey
        self.baseURL = baseURL
        self.modelID = modelID
        self.provider = provider
        self.consentAuthorizer = consentAuthorizer
    }

    func transcribe(audioData: Data, language: String?) async throws -> String {
        try await transcribe(audioData: audioData, language: language, prompt: nil, temperature: nil)
    }

    func transcribe(audioData: Data, language: String?, vocabulary: [String], promptHint: String) async throws -> String {
        try await transcribe(
            audioData: audioData,
            language: language,
            vocabulary: vocabulary,
            promptHint: promptHint,
            temperature: 0
        )
    }

    func transcribe(
        audioData: Data,
        language: String?,
        vocabulary: [String],
        promptHint: String,
        temperature: Double
    ) async throws -> String {
        // Fold the mode's prompt hint (base) with the vocab glossary, matching
        // fonos-core build_stt_prompt.
        let composed = VocabApplier.buildSTTPrompt(base: promptHint, terms: vocabulary)
        return try await transcribe(audioData: audioData, language: language,
                                    prompt: composed.isEmpty ? nil : composed,
                                    temperature: temperature > 0 ? temperature : nil)
    }

    private func transcribe(
        audioData: Data,
        language: String?,
        prompt: String?,
        temperature: Double?
    ) async throws -> String {
        try Task.checkCancellation()
        try validateRemoteAccess()
        let (urlString, url) = try transcriptionEndpoint()
        sttLog.info("🌐 WhisperSTT POST \(urlString), model=\(self.modelID), audioSize=\(audioData.count)")
        let request = makeRequest(
            url: url,
            audioData: audioData,
            language: language,
            prompt: prompt,
            temperature: temperature
        )
        let (data, response) = try await send(request, urlString: urlString)
        try Task.checkCancellation()
        try validate(response: response, data: data)
        return try parseTranscript(from: data)
    }

    private func validateRemoteAccess() throws {
        guard RemoteAITransportPolicy.allows(baseURL) else {
            throw STTError.insecureEndpoint
        }
        guard consentAuthorizer(provider, baseURL) else {
            let destination = RemoteAIEndpointIdentity(provider: provider, baseURL: baseURL)
                .map { "\($0.providerDisplayName) at \($0.origin)" }
                ?? "the configured speech endpoint"
            throw STTError.consentRequired(destination)
        }
    }

    private func transcriptionEndpoint() throws -> (String, URL) {
        let trimmedBaseURL = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var components = URLComponents(string: trimmedBaseURL),
              let scheme = components.scheme,
              !scheme.isEmpty,
              let host = components.host,
              !host.isEmpty else {
            throw STTError.badRequest
        }

        var path = components.percentEncodedPath
        while path.hasSuffix("/") { path.removeLast() }
        if path.hasSuffix("/v1/audio/transcriptions") {
            // Already a complete compatible endpoint.
        } else if path.hasSuffix("/v1") {
            path += "/audio/transcriptions"
        } else {
            path += "/v1/audio/transcriptions"
        }
        components.percentEncodedPath = path
        components.query = nil
        components.fragment = nil

        guard let url = components.url else { throw STTError.badRequest }
        return (url.absoluteString, url)
    }

    private func makeRequest(
        url: URL,
        audioData: Data,
        language: String?,
        prompt: String?,
        temperature: Double?
    ) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        if !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }

        let boundary = UUID().uuidString
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = makeBody(
            boundary: boundary,
            audioData: audioData,
            language: language,
            prompt: prompt,
            temperature: temperature
        )
        return request
    }

    private func makeBody(
        boundary: String,
        audioData: Data,
        language: String?,
        prompt: String?,
        temperature: Double?
    ) -> Data {
        var body = Data()
        // Use actual model ID, not hardcoded "whisper-1"
        appendFormField(&body, boundary: boundary, name: "model", value: modelID)
        appendFormFile(&body, boundary: boundary, name: "file", filename: "audio.wav",
                       mimeType: "audio/wav", data: audioData)
        if let language = STTLanguageCode.normalized(language) {
            appendFormField(&body, boundary: boundary, name: "language", value: language)
        }
        if let prompt, !prompt.isEmpty {
            appendFormField(&body, boundary: boundary, name: "prompt", value: prompt)
        }
        if let temperature {
            appendFormField(
                &body,
                boundary: boundary,
                name: "temperature",
                value: String(min(max(temperature, 0), 1))
            )
        }
        body.append(Data("--\(boundary)--\r\n".utf8))
        return body
    }

    private func send(_ request: URLRequest, urlString: String) async throws -> (Data, URLResponse) {
        do {
            return try await session.data(for: request)
        } catch {
            if error is CancellationError || Task.isCancelled {
                throw CancellationError()
            }
            let desc = (error as? URLError)?.localizedDescription ?? error.localizedDescription
            sttLog.error("🌐 ❌ Request failed: \(desc)")
            if let urlError = error as? URLError {
                switch urlError.code {
                case .cancelled: throw CancellationError()
                case .timedOut: throw STTError.timeout
                case .notConnectedToInternet, .networkConnectionLost: throw STTError.networkUnavailable
                default: throw STTError.recognizerError("Request to \(urlString) failed: \(desc)")
                }
            }
            throw STTError.recognizerError("Request failed: \(desc)")
        }
    }

    private func validate(response: URLResponse, data: Data) throws {
        guard let httpResponse = response as? HTTPURLResponse else {
            throw STTError.parseError
        }

        sttLog.info("🌐 Response: HTTP \(httpResponse.statusCode), body=\(data.count) bytes")

        switch httpResponse.statusCode {
        case 200:
            break
        case 401:
            throw STTError.authenticationFailed
        case 400:
            let body = String(data: data, encoding: .utf8) ?? ""
            sttLog.error("🌐 400 Bad Request: \(body)")
            throw STTError.recognizerError("Bad request: \(body.prefix(200))")
        default:
            let body = String(data: data, encoding: .utf8) ?? ""
            sttLog.error("🌐 HTTP \(httpResponse.statusCode): \(body)")
            throw STTError.recognizerError("Server returned HTTP \(httpResponse.statusCode): \(body.prefix(200))")
        }
    }

    private func parseTranscript(from data: Data) throws -> String {
        // Try standard Whisper response format
        if let decoded = try? JSONDecoder().decode(WhisperResponse.self, from: data) {
            guard !decoded.text.isEmpty else { throw STTError.noTranscript }
            return decoded.text
        }

        // Try alternative response formats (some servers return differently)
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let text = json["text"] as? String ?? json["transcript"] as? String ?? json["result"] as? String {
            guard !text.isEmpty else { throw STTError.noTranscript }
            return text
        }

        let responseStr = String(data: data, encoding: .utf8) ?? "<binary>"
        sttLog.error("🌐 Cannot parse response: \(responseStr.prefix(200))")
        throw STTError.parseError
    }

    // MARK: - Private helpers

    private struct WhisperResponse: Decodable {
        let text: String
    }

    private func appendFormField(_ body: inout Data, boundary: String, name: String, value: String) {
        body.append(Data("--\(boundary)\r\n".utf8))
        body.append(Data("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".utf8))
        body.append(Data("\(value)\r\n".utf8))
    }

    private func appendFormFile(_ body: inout Data, boundary: String, name: String,
                                filename: String, mimeType: String, data: Data) {
        body.append(Data("--\(boundary)\r\n".utf8))
        body.append(Data("Content-Disposition: form-data; name=\"\(name)\"; filename=\"\(filename)\"\r\n".utf8))
        body.append(Data("Content-Type: \(mimeType)\r\n\r\n".utf8))
        body.append(data)
        body.append(Data("\r\n".utf8))
    }
}

// MARK: - WhisperResponseParser

/// Parses OpenAI Whisper API JSON responses.
/// Both standard (`{"text": "..."}`) and verbose_json formats share a top-level `"text"` field.
enum WhisperResponseParser {
    private struct Response: Decodable {
        let text: String
    }

    /// Decodes a Whisper API response and returns the transcript string.
    ///
    /// - Throws: `STTError.parseError` on empty data, malformed JSON, or missing `text` field.
    static func parse(data: Data) throws -> String {
        guard !data.isEmpty else { throw STTError.parseError }
        do {
            let decoded = try JSONDecoder().decode(Response.self, from: data)
            return decoded.text
        } catch {
            throw STTError.parseError
        }
    }
}

// MARK: - FonosResponseParser

/// Parses responses from the local Fonos STT server.
/// Server format: `{"transcript": "...", "confidence": 0.97, "language": "en"}`.
enum FonosResponseParser {
    private struct Response: Decodable {
        let transcript: String
    }

    /// Decodes a Fonos server response and returns the transcript string.
    ///
    /// - Throws: `STTError.parseError` on empty data, malformed JSON, or missing `transcript` field.
    static func parse(data: Data) throws -> String {
        guard !data.isEmpty else { throw STTError.parseError }
        do {
            let decoded = try JSONDecoder().decode(Response.self, from: data)
            return decoded.transcript
        } catch {
            throw STTError.parseError
        }
    }
}
