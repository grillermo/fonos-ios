import Foundation

// MARK: - FonosSTT

/// STT provider that POSTs audio to a local Fonos server and returns the transcript.
///
/// The Fonos server returns JSON: `{"transcript": "...", "confidence": ..., "language": "..."}`.
final class FonosSTT: STTProvider, @unchecked Sendable {

    // MARK: - Properties

    private let session: URLSession
    private let serverURL: URL
    private let consentAuthorizer: RemoteAIConsentStore.Authorizer

    // MARK: - Init

    init(session: URLSession = .shared,
         serverURL: URL = URL(string: "http://localhost:8000") ?? URL(fileURLWithPath: "/"),
         consentAuthorizer: @escaping RemoteAIConsentStore.Authorizer = RemoteAIConsentStore.liveAuthorizer) {
        self.session = session
        self.serverURL = serverURL
        self.consentAuthorizer = consentAuthorizer
    }

    // MARK: - STTProvider

    func transcribe(audioData: Data, language: String?) async throws -> String {
        try Task.checkCancellation()
        guard RemoteAITransportPolicy.allows(serverURL.absoluteString) else {
            throw STTError.insecureEndpoint
        }
        guard consentAuthorizer("fonos", serverURL.absoluteString) else {
            let destination = RemoteAIEndpointIdentity(
                provider: "fonos",
                baseURL: serverURL.absoluteString
            ).map { "\($0.providerDisplayName) at \($0.origin)" }
                ?? "the configured Fonos server"
            throw STTError.consentRequired(destination)
        }
        guard var components = URLComponents(
            url: serverURL.appendingPathComponent("transcribe"),
            resolvingAgainstBaseURL: false
        ) else {
            throw STTError.badRequest
        }
        if let language = STTLanguageCode.normalized(language) {
            components.queryItems = [URLQueryItem(name: "language", value: language)]
        }

        guard let endpoint = components.url else {
            throw STTError.badRequest
        }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"

        let boundary = "FonosSTT-\(UUID().uuidString)"
        request.setValue("multipart/form-data; boundary=\(boundary)",
                         forHTTPHeaderField: "Content-Type")

        var body = Data()
        body.append(Data("--\(boundary)\r\n".utf8))
        body.append(Data("Content-Disposition: form-data; name=\"file\"; filename=\"audio.wav\"\r\n".utf8))
        body.append(Data("Content-Type: audio/wav\r\n\r\n".utf8))
        body.append(audioData)
        body.append(Data("\r\n".utf8))
        body.append(Data("--\(boundary)--\r\n".utf8))
        request.httpBody = body

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
                throw STTError.timeout
            default:
                throw STTError.networkUnavailable
            }
        }
        try Task.checkCancellation()

        guard let http = response as? HTTPURLResponse else {
            throw STTError.parseError
        }

        switch http.statusCode {
        case 200:
            break
        case 401:
            throw STTError.authenticationFailed
        case 400:
            throw STTError.badRequest
        default:
            throw STTError.networkUnavailable
        }

        return try FonosResponseParser.parse(data: data)
    }
}
