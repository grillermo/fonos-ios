import Foundation

/// Encodes/decodes a config bundle to and from the shareable
/// `fonos://config?d=<base64url(zlib(json))>` form used by QR codes and links.
///
/// The decoder is deliberately tolerant so a bundle can arrive as the URL, a
/// bare base64url payload, an uncompressed base64 payload, or raw bundle JSON
/// (e.g. a desktop QR that emits JSON directly). Only the URL form triggers the
/// system Camera's "Open in Fonos".
///
/// A readable `fonos://model?…` link also decodes to a bundle: one model
/// profile plus its default assignments, so it adds a model without touching
/// anything else (see `bundleJSON(fromModelLink:)`).
enum ConfigBundleCodec {
    static let scheme = "fonos"
    static let host = "config"
    static let modelHost = "model"
    static let queryKey = "d"

    /// Bytes a QR holds at a comfortably scannable density (version 40, medium
    /// error correction, byte mode). Conservative on purpose.
    static let qrByteBudget = 2200

    enum CodecError: LocalizedError {
        case invalid
        var errorDescription: String? { "This is not a valid Fonos config code." }
    }

    // MARK: - Encode

    /// `fonos://config?d=<base64url(zlib(json))>`
    static func encodeURL(bundleJSON: Data) -> URL {
        var comps = URLComponents()
        comps.scheme = scheme
        comps.host = host
        comps.queryItems = [URLQueryItem(name: queryKey, value: encodePayload(bundleJSON: bundleJSON))]
        guard let url = comps.url else {
            preconditionFailure("Static Fonos config URL components must form a valid URL")
        }
        return url
    }

    /// The bare `base64url(zlib(json))` payload (no URL wrapper).
    static func encodePayload(bundleJSON: Data) -> String {
        base64url(compress(bundleJSON))
    }

    /// Whether the encoded URL fits inside a single QR code.
    static func fitsQR(bundleJSON: Data) -> Bool {
        encodeURL(bundleJSON: bundleJSON).absoluteString.utf8.count <= qrByteBudget
    }

    // MARK: - Decode (tolerant)

    /// Decode a scanned/pasted string back to bundle JSON. Accepts the
    /// `fonos://config?d=` URL, a bare payload, or raw bundle JSON.
    static func decode(_ scanned: String) throws -> Data {
        let s = scanned.trimmingCharacters(in: .whitespacesAndNewlines)

        // Raw JSON object.
        if s.hasPrefix("{"), let d = s.data(using: .utf8), isJSONObject(d) {
            return d
        }

        // URL form → extract the payload.
        var payload = s
        if let url = URL(string: s), url.scheme?.lowercased() == scheme {
            if url.host?.lowercased() == modelHost {
                return try bundleJSON(fromModelLink: url)
            }
            guard url.host == host,
                  let p = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                    .queryItems?.first(where: { $0.name == queryKey })?.value,
                  !p.isEmpty else {
                throw CodecError.invalid
            }
            payload = p
        }

        guard let raw = dataFromBase64url(payload) else { throw CodecError.invalid }
        // Compressed payload (normal case).
        if let json = decompress(raw), isJSONObject(json) { return json }
        // Uncompressed base64(json) fallback.
        if isJSONObject(raw) { return raw }
        throw CodecError.invalid
    }

    // MARK: - Model links

    /// Builds a models-only bundle from
    /// `fonos://model?base_url=…&model=…[&name=…][&id=…][&provider=…]
    /// [&capabilities=stt,llm][&stt_api=whisper|chat][&api_key=…][&default=stt,llm]`.
    ///
    /// `base_url` and `model` are required. `provider` defaults to `custom`,
    /// `capabilities` to `stt`, and `default` to every capability, so the new
    /// profile becomes the active STT/LLM model. Without `id`, the id is
    /// derived from the endpoint and model, so opening the same link twice
    /// updates the profile instead of adding a copy.
    static func bundleJSON(fromModelLink url: URL) throws -> Data {
        guard let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else {
            throw CodecError.invalid
        }
        func value(_ name: String) -> String? {
            items.first(where: { $0.name == name })?.value?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .nilIfEmpty
        }
        func list(_ name: String) -> [String]? {
            value(name)?.lowercased()
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
        }

        guard let baseURL = value("base_url"),
              RemoteAITransportPolicy.allows(baseURL),
              let host = URLComponents(string: baseURL)?.host,
              let model = value("model") else {
            throw CodecError.invalid
        }
        let provider = value("provider")?.lowercased() ?? "custom"
        let capabilities = (list("capabilities") ?? ["stt"]).filter { $0 == "stt" || $0 == "llm" }
        guard !capabilities.isEmpty else { throw CodecError.invalid }
        let id = value("id") ?? slug("link-\(host)-\(model)")

        var profile: [String: Any] = [
            "id": id,
            "name": value("name") ?? model,
            "provider": provider,
            "model": model,
            "base_url": baseURL,
            "capabilities": capabilities
        ]
        if let sttAPI = value("stt_api") { profile["stt_api"] = sttAPI }
        if let apiKey = value("api_key") { profile["api_key"] = apiKey }

        var assignments: [String: Any] = [:]
        for capability in (list("default") ?? capabilities) where capabilities.contains(capability) {
            assignments["\(capability)_profile"] = id
        }

        let root: [String: Any] = [
            "version": 1,
            "name": value("name") ?? model,
            "models": ["profiles": [profile], "assignments": assignments]
        ]
        return try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
    }

    private static func slug(_ s: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-"))
        return String(s.lowercased().unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" })
    }

    // MARK: - Helpers

    private static func isJSONObject(_ data: Data) -> Bool {
        (try? JSONSerialization.jsonObject(with: data)) is [String: Any]
    }

    private static func compress(_ data: Data) -> Data {
        ((try? (data as NSData).compressed(using: .zlib)) as Data?) ?? data
    }

    private static func decompress(_ data: Data) -> Data? {
        (try? (data as NSData).decompressed(using: .zlib)) as Data?
    }

    private static func base64url(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func dataFromBase64url(_ s: String) -> Data? {
        var b = s.replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while b.count % 4 != 0 { b += "=" }
        return Data(base64Encoded: b)
    }
}
