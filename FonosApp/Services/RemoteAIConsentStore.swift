import Darwin
import Foundation

/// The network destination covered by one explicit remote-AI data-sharing
/// permission. Consent is scoped to both provider and origin so changing a
/// profile from one vendor/server to another requires a fresh decision.
struct RemoteAIEndpointIdentity: Codable, Equatable, Hashable, Identifiable, Sendable {
    let provider: String
    let origin: String

    var id: String { "\(provider)|\(origin)" }

    var providerDisplayName: String {
        switch provider {
        case "openai": "OpenAI"
        case "openrouter": "OpenRouter"
        case "anthropic": "Anthropic"
        case "google": "Google"
        case "ollama": "Ollama"
        case "lmstudio": "LM Studio"
        case "omlx": "OMLX"
        case "fonos": "Fonos server"
        case "custom": "Custom provider"
        default: provider.capitalized
        }
    }

    init?(provider: String, baseURL: String) {
        let normalizedProvider = provider
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let trimmedURL = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedProvider.isEmpty,
              let components = URLComponents(string: trimmedURL),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = components.host?.lowercased(),
              !host.isEmpty else { return nil }

        var normalizedOrigin = "\(scheme)://\(host)"
        if let port = components.port {
            normalizedOrigin += ":\(port)"
        }
        self.provider = normalizedProvider
        self.origin = normalizedOrigin
    }
}

/// Fonos accepts secure public endpoints and explicitly local HTTP endpoints.
/// Public clear-text HTTP is rejected in code in addition to ATS enforcement.
enum RemoteAITransportPolicy {
    static func allows(_ baseURL: String) -> Bool {
        guard let components = URLComponents(string: baseURL),
              let scheme = components.scheme?.lowercased(),
              let host = components.host?.lowercased(),
              !host.isEmpty else { return false }
        if scheme == "https" { return true }
        guard scheme == "http" else { return false }
        return isLocalHost(host)
    }

    static func validationMessage(for baseURL: String) -> String? {
        allows(baseURL)
            ? nil
            : String(
                localized: """
                Use HTTPS for public AI endpoints. \
                HTTP is accepted only for localhost, .local hosts, and private or link-local LAN addresses.
                """
            )
    }

    private static func isLocalHost(_ host: String) -> Bool {
        if host == "localhost" || host.hasSuffix(".localhost") || host.hasSuffix(".local") {
            return true
        }
        if !host.contains(".") && !host.contains(":") {
            return true // Unqualified Bonjour/LAN hostname.
        }
        if let octets = ipv4Octets(host) {
            switch (octets[0], octets[1]) {
            case (10, _), (127, _), (192, 168), (169, 254):
                return true
            case (172, 16 ... 31):
                return true
            default:
                return false
            }
        }
        guard let ipv6 = ipv6Bytes(host) else { return false }
        let isLoopback = ipv6.dropLast().allSatisfy { $0 == 0 } && ipv6.last == 1
        let isUniqueLocal = ipv6[0] & 0xfe == 0xfc // fc00::/7
        let isLinkLocal = ipv6[0] == 0xfe && ipv6[1] & 0xc0 == 0x80 // fe80::/10
        return isLoopback || isUniqueLocal || isLinkLocal
    }

    private static func ipv4Octets(_ host: String) -> [Int]? {
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        let values = parts.compactMap { Int($0) }
        guard values.count == 4, values.allSatisfy({ 0 ... 255 ~= $0 }) else { return nil }
        return values
    }

    /// Parse the complete host as an IPv6 address before inspecting address
    /// ranges. Textual prefix checks alone would misclassify domains such as
    /// `fd.example.com` as unique-local IPv6 hosts.
    private static func ipv6Bytes(_ host: String) -> [UInt8]? {
        // URLComponents preserves the RFC 3986 brackets around IPv6 hosts on
        // current Apple platforms; inet_pton expects only the address bytes.
        let literal: String
        if host.hasPrefix("["), host.hasSuffix("]") {
            literal = String(host.dropFirst().dropLast())
        } else {
            literal = host
        }
        var address = in6_addr()
        let parsed = literal.withCString { pointer in
            inet_pton(AF_INET6, pointer, &address)
        }
        guard parsed == 1 else { return nil }
        return withUnsafeBytes(of: &address) { Array($0) }
    }
}

/// Explicit permissions for sending audio or text to a configured network AI
/// endpoint. The store intentionally contains no API keys or user content.
enum RemoteAIConsentStore {
    typealias Authorizer = @Sendable (_ provider: String, _ baseURL: String) -> Bool

    static let storageKey = "remote_ai_endpoint_consents_v1"
    static let allowAll: Authorizer = { _, _ in true }
    static let liveAuthorizer: Authorizer = { provider, baseURL in
        isAuthorized(provider: provider, baseURL: baseURL)
    }

    static func identity(for profile: ModelProfile) -> RemoteAIEndpointIdentity? {
        RemoteAIEndpointIdentity(provider: profile.provider, baseURL: profile.effectiveBaseURL)
    }

    static func isAuthorized(for profile: ModelProfile, defaults: UserDefaults = .standard) -> Bool {
        isAuthorized(provider: profile.provider, baseURL: profile.effectiveBaseURL, defaults: defaults)
    }

    static func isAuthorized(
        provider: String,
        baseURL: String,
        defaults: UserDefaults = .standard
    ) -> Bool {
        guard RemoteAITransportPolicy.allows(baseURL) else { return false }
        guard let identity = RemoteAIEndpointIdentity(provider: provider, baseURL: baseURL) else {
            return false
        }
        return authorizedEndpoints(defaults: defaults).contains(identity)
    }

    static func grant(for profile: ModelProfile, defaults: UserDefaults = .standard) {
        grant(provider: profile.provider, baseURL: profile.effectiveBaseURL, defaults: defaults)
    }

    static func grant(
        provider: String,
        baseURL: String,
        defaults: UserDefaults = .standard
    ) {
        guard RemoteAITransportPolicy.allows(baseURL) else { return }
        guard let identity = RemoteAIEndpointIdentity(provider: provider, baseURL: baseURL) else {
            return
        }
        var endpoints = authorizedEndpoints(defaults: defaults)
        endpoints.insert(identity)
        persist(endpoints, defaults: defaults)
    }

    static func revoke(for profile: ModelProfile, defaults: UserDefaults = .standard) {
        guard let identity = identity(for: profile) else { return }
        var endpoints = authorizedEndpoints(defaults: defaults)
        endpoints.remove(identity)
        persist(endpoints, defaults: defaults)
    }

    static func revokeAll(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: storageKey)
    }

    static func authorizedEndpoints(defaults: UserDefaults = .standard) -> Set<RemoteAIEndpointIdentity> {
        guard let data = defaults.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode(Set<RemoteAIEndpointIdentity>.self, from: data) else {
            return []
        }
        return decoded
    }

    static func disclosure(for profile: ModelProfile) -> String {
        let identity = identity(for: profile)
        let recipient = identity.map {
            String(
                format: String(localized: "%1$@ at %2$@"),
                $0.providerDisplayName,
                $0.origin
            )
        } ?? String(localized: "the configured provider endpoint")
        var dataTypes: [String] = []
        if profile.hasSTT {
            dataTypes.append(String(localized: "voice recordings"))
        }
        if profile.hasLLM {
            dataTypes.append(String(localized: "transcripts and text prompts"))
        }
        let dataDescription: String
        switch dataTypes.count {
        case 0:
            dataDescription = String(localized: "voice or text data")
        case 1:
            dataDescription = dataTypes[0]
        default:
            dataDescription = String(
                format: String(localized: "%1$@ and %2$@"),
                dataTypes[0],
                dataTypes[1]
            )
        }
        return String(
            format: String(
                localized: """
                Fonos will send %1$@ to %2$@ only when you run a recipe that uses this model. \
                The provider may process the content under its own privacy policy. \
                Your API key remains in Apple Keychain.
                """
            ),
            dataDescription,
            recipient
        )
    }

    private static func persist(
        _ endpoints: Set<RemoteAIEndpointIdentity>,
        defaults: UserDefaults
    ) {
        guard !endpoints.isEmpty else {
            defaults.removeObject(forKey: storageKey)
            return
        }
        if let data = try? JSONEncoder().encode(endpoints) {
            defaults.set(data, forKey: storageKey)
        }
    }
}
