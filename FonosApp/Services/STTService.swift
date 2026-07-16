import Foundation
import Speech
import os.log

let sttLog = Logger(subsystem: "com.fonos.ios", category: "STT")

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
