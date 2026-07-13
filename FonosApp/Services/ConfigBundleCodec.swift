import Foundation

/// Encodes/decodes a config bundle to and from the shareable
/// `fonos://config?d=<base64url(zlib(json))>` form used by QR codes and links.
///
/// The decoder is deliberately tolerant so a bundle can arrive as the URL, a
/// bare base64url payload, an uncompressed base64 payload, or raw bundle JSON
/// (e.g. a desktop QR that emits JSON directly). Only the URL form triggers the
/// system Camera's "Open in Fonos".
enum ConfigBundleCodec {
    static let scheme = "fonos"
    static let host = "config"
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
