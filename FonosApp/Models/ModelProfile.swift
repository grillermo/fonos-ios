import Foundation

enum ModelProfileReference {
    /// Shared desktop/iOS sentinel for the platform Apple Speech adapter.
    static let appleSpeech = "apple-speech"

    static func normalized(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Represents a configured AI model profile (STT, LLM, or both).
struct ModelProfile: Codable, Equatable, Hashable, Identifiable, Sendable {
    var id: String              // e.g., "openai-1234567890"
    var name: String            // User-friendly name
    var provider: String        // openai, anthropic, google, ollama, lmstudio, custom
    var modelID: String         // Model identifier (e.g., "gpt-4o")
    var baseURL: String?        // Custom endpoint URL
    var capabilities: [String]  // ["stt", "llm"] or subset
    /// Desktop profile contract: `whisper` multipart or multimodal `chat`.
    /// Optional keeps pre-Flow iOS AppConfig decoding backward compatible.
    var sttAPI: String?

    // MARK: - Convenience

    /// True if this model can perform speech-to-text.
    var hasSTT: Bool { capabilities.contains("stt") }

    /// True if this model can perform LLM processing.
    var hasLLM: Bool { capabilities.contains("llm") }

    var effectiveSTTAPI: String {
        // Match fonos-core exactly: only the canonical lowercase value opts
        // into chat; absent or malformed values use Whisper.
        sttAPI == "chat" ? "chat" : "whisper"
    }

    /// Scenario contract stores a service base URL, never a concrete chat
    /// endpoint. Canonicalizing here keeps iOS-authored profiles executable on
    /// desktop, whose client appends `/v1/chat/completions` itself.
    var portableBaseURL: String? {
        Self.normalizeBaseURL(baseURL)
    }

    /// Same provider defaults as fonos-core/services.rs.
    var effectiveBaseURL: String {
        if let portableBaseURL, !portableBaseURL.isEmpty {
            return portableBaseURL
        }
        switch provider.lowercased() {
        case "omlx": return "http://localhost:8000"
        case "ollama": return "http://localhost:11434"
        case "openai": return "https://api.openai.com"
        case "openrouter": return "https://openrouter.ai/api/v1"
        case "anthropic": return "https://api.anthropic.com"
        case "google": return "https://generativelanguage.googleapis.com"
        case "fonos": return "http://localhost:9880"
        default: return ""
        }
    }

    // MARK: - Init

    init(
        id: String,
        name: String,
        provider: String,
        modelID: String,
        baseURL: String? = nil,
        capabilities: [String] = ["llm"],
        sttAPI: String? = nil
    ) {
        self.id = id
        self.name = name
        self.provider = provider
        self.modelID = modelID
        self.baseURL = Self.normalizeBaseURL(baseURL)
        self.capabilities = capabilities
        self.sttAPI = sttAPI
    }

    private static func normalizeBaseURL(_ rawValue: String?) -> String? {
        guard let rawValue else { return nil }
        var value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !value.isEmpty else { return nil }
        let lowercase = value.lowercased()
        let suffixes = ["/v1/chat/completions", "/chat/completions"]
        if let suffix = suffixes.first(where: { lowercase.hasSuffix($0) }) {
            value.removeLast(suffix.count)
            value = value.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        }
        return value.isEmpty ? nil : value
    }
}
