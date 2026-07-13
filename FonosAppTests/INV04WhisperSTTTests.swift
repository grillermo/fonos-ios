// INV-04: WhisperSTT POSTs WAV to OpenAI endpoint, parses response, returns transcript.
// Handles 401, 400, timeout errors gracefully.
//
// Verifier: auto
// Level: unit (URLSession intercepted via URLProtocol subclass)
// Run: xcodebuild test -scheme FonosApp -only-testing:FonosAppTests/INV04WhisperSTTTests

import Testing
import Foundation
@testable import FonosApp

// MARK: - Mock URLProtocol

private final class MockURLProtocol: URLProtocol {
    nonisolated(unsafe) static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = MockURLProtocol.requestHandler else {
            client?.urlProtocol(self, didFailWithError: URLError(.unknown))
            return
        }
        do {
            // URLSession moves httpBody to httpBodyStream for URLProtocol interceptors.
            // Reconstruct httpBody so handler closures can read req.httpBody directly.
            var enrichedRequest = request
            if enrichedRequest.httpBody == nil, let stream = enrichedRequest.httpBodyStream {
                stream.open()
                var bodyData = Data()
                let bufferSize = 4096
                let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
                defer { buffer.deallocate() }
                while stream.hasBytesAvailable {
                    let read = stream.read(buffer, maxLength: bufferSize)
                    if read > 0 { bodyData.append(buffer, count: read) }
                }
                stream.close()
                enrichedRequest.httpBody = bodyData
            }
            let (response, data) = try handler(enrichedRequest)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

// MARK: - Helpers

private func makeSession() -> URLSession {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [MockURLProtocol.self]
    return URLSession(configuration: config)
}

private func makeWhisperSTT(session: URLSession, apiKey: String = "sk-test") -> WhisperSTT {
    authorizedWhisperSTT(session: session, apiKey: apiKey)
}

private func okResponse(for url: URL, body: String) -> (HTTPURLResponse, Data) {
    let resp = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
    return (resp, body.data(using: .utf8)!)
}

private func errorResponse(for url: URL, statusCode: Int) -> (HTTPURLResponse, Data) {
    let resp = HTTPURLResponse(url: url, statusCode: statusCode, httpVersion: nil, headerFields: nil)!
    return (resp, Data())
}

private let kOpenAITranscriptURL = URL(string: "https://api.openai.com/v1/audio/transcriptions")!

private func dummyWAVData() -> Data {
    var header = [UInt8](repeating: 0, count: 44)
    "RIFF".utf8.enumerated().forEach { header[$0.offset] = $0.element }
    "WAVE".utf8.enumerated().forEach { header[8 + $0.offset] = $0.element }
    return Data(header)
}

// MARK: - Tests

// Serialized because MockURLProtocol.requestHandler is a shared static variable
// that would race under concurrent test execution.
@Suite(.serialized)
struct INV04WhisperSTTTests {

    // --- Protocol conformance ---

    @Test("WhisperSTT conforms to STTProvider protocol")
    func protocolConformance() throws {
        let stt: any STTProvider = authorizedWhisperSTT(session: .shared, apiKey: "sk-test")
        _ = stt
        #expect(Bool(true))
    }

    // --- Request construction ---

    @Test("WhisperSTT sends multipart/form-data Content-Type header")
    func requestHasMultipartContentType() async throws {
        var capturedRequest: URLRequest?
        MockURLProtocol.requestHandler = { req in
            capturedRequest = req
            return okResponse(for: kOpenAITranscriptURL, body: #"{"text":"hello"}"#)
        }
        let stt = makeWhisperSTT(session: makeSession())
        _ = try? await stt.transcribe(audioData: dummyWAVData(), language: "en")
        let ct = capturedRequest?.value(forHTTPHeaderField: "Content-Type") ?? ""
        #expect(ct.contains("multipart/form-data"))
    }

    @Test("WhisperSTT sends Authorization header with Bearer token")
    func requestHasAuthorizationHeader() async throws {
        var capturedRequest: URLRequest?
        MockURLProtocol.requestHandler = { req in
            capturedRequest = req
            return okResponse(for: kOpenAITranscriptURL, body: #"{"text":"hello"}"#)
        }
        let stt = makeWhisperSTT(session: makeSession(), apiKey: "sk-mykey")
        _ = try? await stt.transcribe(audioData: dummyWAVData(), language: "en")
        let auth = capturedRequest?.value(forHTTPHeaderField: "Authorization") ?? ""
        #expect(auth == "Bearer sk-mykey")
    }

    @Test("WhisperSTT POSTs to OpenAI transcriptions endpoint")
    func requestTargetsCorrectURL() async throws {
        var capturedRequest: URLRequest?
        MockURLProtocol.requestHandler = { req in
            capturedRequest = req
            return okResponse(for: kOpenAITranscriptURL, body: #"{"text":"hello"}"#)
        }
        let stt = makeWhisperSTT(session: makeSession())
        _ = try? await stt.transcribe(audioData: dummyWAVData(), language: "en")
        #expect(capturedRequest?.url?.host == "api.openai.com")
        #expect(capturedRequest?.url?.path == "/v1/audio/transcriptions")
        #expect(capturedRequest?.httpMethod == "POST")
    }

    // --- Response parsing ---

    @Test("WhisperSTT parses standard {\"text\": ...} response")
    func parsesStandardResponse() async throws {
        MockURLProtocol.requestHandler = { _ in
            okResponse(for: kOpenAITranscriptURL, body: #"{"text":"hello world"}"#)
        }
        let stt = makeWhisperSTT(session: makeSession())
        let result = try await stt.transcribe(audioData: dummyWAVData(), language: "en")
        #expect(result == "hello world")
    }

    // --- Error handling ---

    @Test("WhisperSTT throws authentication error on 401 response")
    func throws401AsAuthError() async throws {
        MockURLProtocol.requestHandler = { _ in
            errorResponse(for: kOpenAITranscriptURL, statusCode: 401)
        }
        let stt = makeWhisperSTT(session: makeSession())
        await #expect(throws: STTError.authenticationFailed) {
            _ = try await stt.transcribe(audioData: dummyWAVData(), language: "en")
        }
    }

    @Test("WhisperSTT throws descriptive error on 400 response")
    func throws400AsBadRequest() async throws {
        MockURLProtocol.requestHandler = { _ in
            errorResponse(for: kOpenAITranscriptURL, statusCode: 400)
        }
        let stt = makeWhisperSTT(session: makeSession())
        do {
            _ = try await stt.transcribe(audioData: dummyWAVData(), language: "en")
            Issue.record("Should have thrown")
        } catch {
            #expect(error is STTError)
        }
    }

    @Test("WhisperSTT throws timeout error on URLError.timedOut")
    func throwsTimeoutError() async throws {
        MockURLProtocol.requestHandler = { _ in
            throw URLError(.timedOut)
        }
        let stt = makeWhisperSTT(session: makeSession())
        await #expect(throws: STTError.timeout) {
            _ = try await stt.transcribe(audioData: dummyWAVData(), language: "en")
        }
    }

    @Test("WhisperSTT throws parse error on malformed JSON response")
    func throwsOnMalformedJSON() async throws {
        MockURLProtocol.requestHandler = { _ in
            okResponse(for: kOpenAITranscriptURL, body: "not-json{{{")
        }
        let stt = makeWhisperSTT(session: makeSession())
        await #expect(throws: STTError.parseError) {
            _ = try await stt.transcribe(audioData: dummyWAVData(), language: "en")
        }
    }

    // --- Language parameter ---

    @Test("WhisperSTT includes language parameter in request body when non-nil")
    func includesLanguageParameter() async throws {
        var capturedBodyString = ""
        MockURLProtocol.requestHandler = { req in
            if let body = req.httpBody {
                capturedBodyString = String(data: body, encoding: .utf8) ?? ""
            }
            return okResponse(for: kOpenAITranscriptURL, body: #"{"text":"bonjour"}"#)
        }
        let stt = makeWhisperSTT(session: makeSession())
        _ = try? await stt.transcribe(audioData: dummyWAVData(), language: "fr")
        #expect(capturedBodyString.contains("fr"))
    }

    @Test("WhisperSTT sends workflow prompt and temperature")
    func includesWorkflowTuning() async throws {
        var capturedBodyString = ""
        MockURLProtocol.requestHandler = { req in
            if let body = req.httpBody {
                capturedBodyString = String(data: body, encoding: .utf8) ?? ""
            }
            return okResponse(for: kOpenAITranscriptURL, body: #"{"text":"Fonos"}"#)
        }

        let stt = makeWhisperSTT(session: makeSession())
        _ = try await stt.transcribe(
            audioData: dummyWAVData(),
            language: "en",
            vocabulary: ["Fonos"],
            promptHint: "Product names",
            temperature: 0.35
        )

        #expect(capturedBodyString.contains("Product names"))
        #expect(capturedBodyString.contains("Fonos"))
        #expect(capturedBodyString.contains("name=\"temperature\""))
        #expect(capturedBodyString.contains("0.35"))
    }

    @Test("WhisperSTT omits a zero workflow temperature like desktop")
    func omitsZeroWorkflowTemperature() async throws {
        var capturedBodyString = ""
        MockURLProtocol.requestHandler = { request in
            capturedBodyString = request.httpBody
                .flatMap { String(data: $0, encoding: .utf8) } ?? ""
            return okResponse(for: kOpenAITranscriptURL, body: #"{"text":"hello"}"#)
        }
        let stt = makeWhisperSTT(session: makeSession())

        _ = try await stt.transcribe(
            audioData: dummyWAVData(),
            language: nil,
            vocabulary: [],
            promptHint: "",
            temperature: 0
        )

        #expect(!capturedBodyString.contains("name=\"temperature\""))
    }

    @Test("ChatSTT mirrors the desktop input_audio request contract")
    func chatSTTRequestContract() async throws {
        var capturedRequest: URLRequest?
        var capturedBody: [String: Any] = [:]
        MockURLProtocol.requestHandler = { request in
            capturedRequest = request
            if let body = request.httpBody {
                capturedBody = try JSONSerialization.jsonObject(with: body) as? [String: Any] ?? [:]
            }
            let url = request.url!
            return okResponse(
                for: url,
                body: #"{"choices":[{"message":{"content":"  Fonos transcript  "}}]}"#
            )
        }
        let wav = dummyWAVData()
        let stt = authorizedChatSTT(
            session: makeSession(),
            apiKey: "chat-key",
            baseURL: "https://openrouter.ai/api/v1",
            modelID: "openai/gpt-audio-mini"
        )

        let transcript = try await stt.transcribe(
            audioData: wav,
            language: "zh",
            vocabulary: ["Fonos", "SwiftData"],
            promptHint: "ignored by desktop chat STT",
            temperature: 0.9
        )

        #expect(capturedRequest?.url?.path == "/api/v1/chat/completions")
        #expect(capturedRequest?.value(forHTTPHeaderField: "Authorization") == "Bearer chat-key")
        #expect(capturedBody["model"] as? String == "openai/gpt-audio-mini")
        #expect(capturedBody["temperature"] as? Double == 0)
        #expect(capturedBody["max_tokens"] as? Int == 4096)
        let messages = capturedBody["messages"] as? [[String: Any]]
        let content = messages?.first?["content"] as? [[String: Any]]
        #expect((content?.first?["text"] as? String)?.contains("language code 'zh'") == true)
        #expect((content?.first?["text"] as? String)?.contains("Fonos, SwiftData") == true)
        let audio = content?[safe: 1]?["input_audio"] as? [String: String]
        #expect(audio?["data"] == wav.base64EncodedString())
        #expect(audio?["format"] == "wav")
        #expect(transcript == "Fonos transcript")
    }

    @Test("ChatSTT rejects an empty completion")
    func chatSTTRejectsEmptyCompletion() async throws {
        MockURLProtocol.requestHandler = { request in
            okResponse(for: request.url!, body: #"{"choices":[{"message":{"content":"  "}}]}"#)
        }
        let stt = authorizedChatSTT(
            session: makeSession(),
            apiKey: "",
            baseURL: "https://example.com/chat/completions",
            modelID: "audio"
        )
        await #expect(throws: STTError.noTranscript) {
            _ = try await stt.transcribe(audioData: dummyWAVData(), language: nil)
        }
    }
}

private extension Array {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
