import Foundation
import Speech
import os.log

private let sttLog = Logger(subsystem: "com.fonos.ios", category: "STT")

private final class SpeechRecognitionCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private var didFinish = false
    private var shouldCancelTaskOnInstall = false
    private var task: SFSpeechRecognitionTask?
    private let continuation: CheckedContinuation<String, any Error>

    init(_ continuation: CheckedContinuation<String, any Error>) {
        self.continuation = continuation
    }

    func setTask(_ task: SFSpeechRecognitionTask) {
        lock.lock()
        self.task = task
        let shouldCancel = shouldCancelTaskOnInstall
        lock.unlock()
        if shouldCancel {
            task.cancel()
        }
    }

    func succeed(_ text: String) {
        finish {
            if text.isEmpty {
                continuation.resume(throwing: STTError.noTranscript)
            } else {
                continuation.resume(returning: text)
            }
        }
    }

    func fail(_ error: Error) {
        finish {
            continuation.resume(throwing: error)
        }
    }

    func timeout() {
        lock.lock()
        guard !didFinish else {
            lock.unlock()
            return
        }
        didFinish = true
        shouldCancelTaskOnInstall = true
        let task = task
        lock.unlock()

        task?.cancel()
        continuation.resume(throwing: STTError.timeout)
    }

    func cancel() {
        lock.lock()
        guard !didFinish else {
            lock.unlock()
            return
        }
        didFinish = true
        shouldCancelTaskOnInstall = true
        let task = task
        lock.unlock()

        task?.cancel()
        continuation.resume(throwing: CancellationError())
    }

    var canStartRecognition: Bool {
        lock.lock()
        defer { lock.unlock() }
        return !didFinish
    }

    private func finish(_ resume: () -> Void) {
        lock.lock()
        guard !didFinish else {
            lock.unlock()
            return
        }
        didFinish = true
        lock.unlock()
        resume()
    }
}

/// Connects task cancellation to a completion that is created inside the
/// continuation body. It handles cancellation both before and after install.
private final class SpeechRecognitionCancellationRelay: @unchecked Sendable {
    private let lock = NSLock()
    private var completion: SpeechRecognitionCompletion?
    private var wasCancelled = false

    func install(_ completion: SpeechRecognitionCompletion) {
        lock.lock()
        self.completion = completion
        let shouldCancel = wasCancelled
        lock.unlock()

        if shouldCancel {
            completion.cancel()
        }
    }

    func cancel() {
        lock.lock()
        wasCancelled = true
        let completion = completion
        lock.unlock()
        completion?.cancel()
    }
}

// MARK: - STTProvider Protocol

/// Protocol all STT provider implementations must conform to.
protocol STTProvider: Sendable {
    func transcribe(audioData: Data, language: String?) async throws -> String

    /// Vocabulary-aware transcription. `vocabulary` is the domain terms used
    /// for biasing (Apple `contextualStrings`, Whisper prompt); `promptHint`
    /// is the mode's Whisper prompt used as the prompt base (fonos-core
    /// `build_stt_prompt`). Providers that support biasing override this; the
    /// default ignores both.
    func transcribe(audioData: Data, language: String?, vocabulary: [String], promptHint: String) async throws -> String

    /// Fully configured workflow entry point. Providers that expose a sampling
    /// temperature should override this; the default preserves compatibility
    /// with providers whose API has no such control (for example Apple Speech).
    func transcribe(
        audioData: Data,
        language: String?,
        vocabulary: [String],
        promptHint: String,
        temperature: Double
    ) async throws -> String
}

extension STTProvider {
    func transcribe(audioData: Data, language: String?, vocabulary: [String], promptHint: String) async throws -> String {
        try await transcribe(audioData: audioData, language: language)
    }

    func transcribe(
        audioData: Data,
        language: String?,
        vocabulary: [String],
        promptHint: String,
        temperature: Double
    ) async throws -> String {
        try await transcribe(
            audioData: audioData,
            language: language,
            vocabulary: vocabulary,
            promptHint: promptHint
        )
    }

    /// Convenience for callers that have no mode prompt hint.
    func transcribe(audioData: Data, language: String?, vocabulary: [String]) async throws -> String {
        try await transcribe(audioData: audioData, language: language, vocabulary: vocabulary, promptHint: "")
    }
}

/// Desktop stores human-readable language names in STT widget props, then
/// normalizes them at the execution boundary. Keep the same wire values and
/// conversion so imported recipes work with APIs that require language codes.
enum STTLanguageCode {
    static func normalized(_ language: String?) -> String? {
        guard let language else { return nil }
        let trimmed = language.trimmingCharacters(in: .whitespacesAndNewlines)
        let value = trimmed.lowercased()
        guard !value.isEmpty, value != "auto" else { return nil }
        let names: [String: String] = [
            "chinese": "zh",
            "english": "en",
            "japanese": "ja",
            "korean": "ko",
            "cantonese": "yue",
            "french": "fr",
            "german": "de",
            "spanish": "es",
            "portuguese": "pt",
            "italian": "it",
            "russian": "ru",
            "arabic": "ar",
            "hindi": "hi",
            "thai": "th",
            "vietnamese": "vi",
            "dutch": "nl",
            "polish": "pl",
            "turkish": "tr",
            "indonesian": "id"
        ]
        return names[value] ?? trimmed
    }

    static func appleLocaleIdentifier(_ language: String?) -> String? {
        guard let code = normalized(language) else { return nil }
        let locales: [String: String] = [
            "zh": "zh-CN", "en": "en-US", "ja": "ja-JP", "ko": "ko-KR",
            "fr": "fr-FR", "de": "de-DE", "es": "es-ES", "pt": "pt-BR",
            "it": "it-IT", "ru": "ru-RU", "ar": "ar-SA", "th": "th-TH",
            "vi": "vi-VN", "nl": "nl-NL", "pl": "pl-PL", "tr": "tr-TR",
            "id": "id-ID"
        ]
        return locales[code.lowercased()] ?? code
    }
}

// MARK: - STTResolver

/// Resolves the STT provider for an AppConfig. Shared by DictationViewModel
/// and NoteViewModel so both surfaces honour the configured model profile.
enum STTResolver {
    static func resolve(config: AppConfig, profileID overrideProfileID: String? = nil) -> any STTProvider {
        let profileID = ModelProfileReference.normalized(
            overrideProfileID ?? config.sttProfile
        )
        guard !profileID.isEmpty else {
            sttLog.info("🔌 No STT profile configured, using Apple Speech")
            return AppleSTT()
        }
        if profileID == ModelProfileReference.appleSpeech {
            sttLog.info("🔌 Explicit Apple Speech adapter selected")
            return AppleSTT()
        }
        guard let profile = config.modelProfiles.first(where: { $0.id == profileID }),
              profile.hasSTT else {
            return UnavailableSTT(reason: "STT model profile '\(profileID)' is unavailable")
        }
        let key = (try? KeychainStore(service: "com.fonos.models").get(profile.id)) ?? ""
        let baseURL = profile.effectiveBaseURL
        sttLog.info("🔌 Resolving STT: provider=\(profile.provider), model=\(profile.modelID), baseURL=\(baseURL)")

        switch profile.provider.lowercased() {
        case "apple":
            return AppleSTT()
        case "fonos":
            guard let url = URL(string: baseURL)
                ?? URL(string: "http://localhost:9880") else {
                return UnavailableSTT(reason: "The local Fonos endpoint is invalid")
            }
            return FonosSTT(serverURL: url)
        default:
            guard !baseURL.isEmpty else {
                return UnavailableSTT(reason: "STT profile '\(profile.name)' has no endpoint")
            }
            if profile.effectiveSTTAPI == "chat" {
                return ChatSTT(
                    apiKey: key,
                    baseURL: baseURL,
                    modelID: profile.modelID,
                    provider: profile.provider
                )
            }
            return WhisperSTT(
                apiKey: key,
                baseURL: baseURL,
                modelID: profile.modelID,
                provider: profile.provider
            )
        }
    }
}

private struct UnavailableSTT: STTProvider {
    let reason: String

    func transcribe(audioData: Data, language: String?) async throws -> String {
        throw STTError.profileUnavailable(reason)
    }
}

// MARK: - ChatSTT

/// STT provider for multimodal models exposed through an OpenAI-compatible
/// chat-completions endpoint. This mirrors fonos-core's `transcribe_chat`
/// contract: the complete WAV is sent as base64 `input_audio`, alongside a
/// deterministic transcription instruction and optional language/vocabulary
/// hints.
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
enum STTError: LocalizedError, Equatable {
    case permissionDenied
    case noTranscript
    case authenticationFailed
    case badRequest
    case timeout
    case parseError
    case networkUnavailable
    case recognizerError(String)
    case transcriptionFailed
    case profileUnavailable(String)
    case consentRequired(String)
    case insecureEndpoint

    var errorDescription: String? {
        switch self {
        case .permissionDenied:       "Microphone or speech recognition permission denied. Enable in Settings."
        case .noTranscript:           "No transcription result returned."
        case .authenticationFailed:   "Authentication failed — check your API key."
        case .badRequest:             "Bad request — check the audio format or parameters."
        case .timeout:                "Request timed out. Check your network connection."
        case .parseError:             "Failed to parse the server response."
        case .networkUnavailable:     "Network unavailable. Check your connection."
        case .recognizerError(let m): "Recognizer error: \(m)"
        case .transcriptionFailed:    "Transcription failed."
        case .profileUnavailable(let reason): reason
        case .consentRequired(let destination):
            "Permission is required before sending audio to \(destination). Review this model under Settings → Models."
        case .insecureEndpoint:
            "Public speech endpoints must use HTTPS. HTTP is allowed only for a local server on this device or LAN."
        }
    }
}

// MARK: - SpeechRecognizerProtocol

/// Protocol seam allowing AppleSTT to work with both the real SFSpeechRecognizer
/// and mock implementations injected during tests.
struct SpeechRecognitionOutput: Equatable, Sendable {
    let transcript: String
    let isFinal: Bool
}

protocol SpeechRecognizerProtocol: Sendable {
    /// Switch the underlying recognizer to a new locale. Default no-op for mocks.
    func updateLocale(_ locale: Locale)

    func requestAuthorization(_ handler: @escaping (SFSpeechRecognizerAuthorizationStatus) -> Void)
    func recognize(request: SFSpeechAudioBufferRecognitionRequest,
                   resultHandler: @escaping (SpeechRecognitionOutput?, Error?) -> Void) -> SFSpeechRecognitionTask
}

extension SpeechRecognizerProtocol {
    /// Default no-op so test mocks don't need to implement locale switching.
    func updateLocale(_ locale: Locale) {}
}

// MARK: - RealSpeechRecognizer

/// Production wrapper that delegates to SFSpeechRecognizer.
final class RealSpeechRecognizer: SpeechRecognizerProtocol, @unchecked Sendable {
    private var recognizer: SFSpeechRecognizer

    init(locale: Locale = .current) {
        // SFSpeechRecognizer(locale:) returns nil only for truly unsupported locales.
        // Fall back to the device locale, then to English if unavailable.
        let englishLocale = Locale(identifier: "en-US")
        if let localRecognizer = SFSpeechRecognizer(locale: locale) {
            self.recognizer = localRecognizer
        } else if let englishRecognizer = SFSpeechRecognizer(locale: englishLocale) {
            self.recognizer = englishRecognizer
        } else {
            // SFSpeechRecognizer requires at least one supported locale; use system default.
            self.recognizer = SFSpeechRecognizer(locale: .current) ?? {
                fatalError("SFSpeechRecognizer is unavailable on this device.")
            }()
        }
    }

    func updateLocale(_ locale: Locale) {
        recognizer = SFSpeechRecognizer(locale: locale) ?? recognizer
    }

    func requestAuthorization(_ handler: @escaping (SFSpeechRecognizerAuthorizationStatus) -> Void) {
        SFSpeechRecognizer.requestAuthorization(handler)
    }

    func recognize(request: SFSpeechAudioBufferRecognitionRequest,
                   resultHandler: @escaping (SpeechRecognitionOutput?, Error?) -> Void) -> SFSpeechRecognitionTask {
        recognizer.recognitionTask(with: request) { result, error in
            let output = result.map {
                SpeechRecognitionOutput(
                    transcript: $0.bestTranscription.formattedString,
                    isFinal: $0.isFinal
                )
            }
            resultHandler(output, error)
        }
    }
}

// MARK: - AppleSTT

/// STT provider that uses on-device Apple Speech recognition.
///
/// Accepts an injectable `SpeechRecognizerProtocol` for testability.
final class AppleSTT: STTProvider, @unchecked Sendable {

    // MARK: - Properties

    private let recognizer: any SpeechRecognizerProtocol

    /// The locale last used in a transcription call. Exposed for test inspection.
    private(set) var lastUsedLocale: Locale?

    // MARK: - Init

    init(recognizer: any SpeechRecognizerProtocol = RealSpeechRecognizer()) {
        self.recognizer = recognizer
    }

    // MARK: - STTProvider conformance

    func transcribe(audioData: Data, language: String?) async throws -> String {
        try await transcribe(buffer: audioData, language: language)
    }

    func transcribe(audioData: Data, language: String?, vocabulary: [String], promptHint: String) async throws -> String {
        // Apple biases via contextualStrings (terms only); the prose promptHint
        // is a Whisper concept and does not apply here.
        try await transcribe(buffer: audioData, language: language, vocabulary: vocabulary)
    }

    // MARK: - Buffer-based transcription (test-facing API)

    /// Transcribes audio data, setting `lastUsedLocale` from the `language` parameter
    /// AND switching the underlying SFSpeechRecognizer to that locale so non-system
    /// languages (e.g. notebook configured for zh-CN on an en-US device) are
    /// actually recognized — not just recorded as "intended".
    func transcribe(buffer audioData: Data, language: String?, vocabulary: [String] = []) async throws -> String {
        try Task.checkCancellation()
        let targetLocale = STTLanguageCode.appleLocaleIdentifier(language)
            .map { Locale(identifier: $0) } ?? .current
        lastUsedLocale = targetLocale
        // The previous bug: this line was missing. lastUsedLocale was being set
        // for test introspection but the actual recognizer kept its init-time
        // locale (.current), so per-notebook language overrides had no effect.
        recognizer.updateLocale(targetLocale)

        let cancellationRelay = SpeechRecognitionCancellationRelay()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let completion = SpeechRecognitionCompletion(continuation)
                cancellationRelay.install(completion)

                recognizer.requestAuthorization { [recognizer = self.recognizer] status in
                    guard status == .authorized else {
                        completion.fail(STTError.permissionDenied)
                        return
                    }
                    guard completion.canStartRecognition else { return }

                    let request = SFSpeechAudioBufferRecognitionRequest()
                    request.shouldReportPartialResults = false
                    if !vocabulary.isEmpty {
                        request.contextualStrings = vocabulary
                    }

                    // Append audio data to the request — this was missing!
                    // Convert WAV data to PCM buffer and feed it to the recognizer.
                    if audioData.count > 44 {
                        // Try to decode WAV → PCM buffer
                        if let pcmBuffer = try? AudioCaptureService.decodeWAV(data: audioData) {
                            request.append(pcmBuffer)
                        } else {
                            // Fallback: try to create a buffer directly from raw PCM (skip WAV header)
                            let pcmData = audioData.dropFirst(44)
                            let sampleCount = pcmData.count / 2 // 16-bit samples
                            if let format = AVAudioFormat(
                                commonFormat: .pcmFormatInt16,
                                sampleRate: 16_000,
                                channels: 1,
                                interleaved: false
                            ), let buffer = AVAudioPCMBuffer(
                                pcmFormat: format,
                                frameCapacity: AVAudioFrameCount(sampleCount)
                            ) {
                                buffer.frameLength = AVAudioFrameCount(sampleCount)
                                if let int16Ptr = buffer.int16ChannelData {
                                    pcmData.withUnsafeBytes { rawBuf in
                                        if let baseAddr = rawBuf.baseAddress {
                                            memcpy(int16Ptr[0], baseAddr, pcmData.count)
                                        }
                                    }
                                    request.append(buffer)
                                }
                            }
                        }
                    }
                    // Signal end of audio — without this, the recognizer waits forever
                    request.endAudio()

                    let task = recognizer.recognize(request: request) { result, error in

                        if let error {
                            completion.fail(STTError.recognizerError(error.localizedDescription))
                            return
                        }

                        if let result, result.isFinal {
                            completion.succeed(result.transcript)
                            return
                        }

                        if result == nil && error == nil {
                            completion.fail(STTError.noTranscript)
                        }
                    }
                    completion.setTask(task)

                    DispatchQueue.main.asyncAfter(deadline: .now() + 15) {
                        completion.timeout()
                    }
                }
            }
        } onCancel: {
            cancellationRelay.cancel()
        }
    }
}

// MARK: - WhisperSTT

/// STT provider that sends audio to an OpenAI-compatible transcription API.
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
        let urlString = "\(baseURL)/v1/audio/transcriptions"
        guard let url = URL(string: urlString) else {
            throw STTError.badRequest
        }
        return (urlString, url)
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
