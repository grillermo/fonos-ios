import Darwin
import Foundation
import Network
import os.log

private let routeLog = Logger(subsystem: "com.fonos.ios", category: "EndpointRouter")

// MARK: - EndpointRouter

/// Chooses between a model profile's primary endpoint (typically a LAN
/// address such as `http://192.168.1.3:8787`) and its fallback (a public
/// tunnel such as `https://mema.chiq.me`) without paying for a reachability
/// check on every request.
///
/// 1. **Free subnet gate.** When the primary host is a literal IPv4 address,
///    it is only considered if one of the phone's active interfaces sits on
///    the same subnet (`getifaddrs`, no network traffic, no Wi-Fi/SSID or
///    location permission). Away from home the fallback is used immediately.
/// 2. **One cached probe per network.** On a matching network a short TCP
///    connect (`probeTimeout`) checks the primary once. The verdict is keyed
///    by a fingerprint of the local interface addresses, so it is reused for
///    every request until the network changes or the verdict expires.
/// 3. **Request failure demotes.** If a real request to the primary fails,
///    the caller reports it and the primary is skipped for `downTTL`.
///
/// Callers prewarm the verdict when a workflow is compiled (recording start),
/// so the probe normally completes while the user is still speaking.
actor EndpointRouter {
    static let shared = EndpointRouter()

    struct Verdict: Equatable {
        let reachable: Bool
        let network: String
        let decidedAt: Date
    }

    typealias Prober = @Sendable (_ host: String, _ port: UInt16, _ timeout: TimeInterval) async -> Bool
    typealias NetworkReader = @Sendable (_ host: String) -> LocalNetworkFingerprint

    private let prober: Prober
    private let networkReader: NetworkReader
    private let now: @Sendable () -> Date
    nonisolated let probeTimeout: TimeInterval
    nonisolated let upTTL: TimeInterval
    nonisolated let downTTL: TimeInterval

    private var verdicts: [String: Verdict] = [:]
    private var inflight: [String: Task<Bool, Never>] = [:]

    init(
        probeTimeout: TimeInterval = 0.8,
        upTTL: TimeInterval = 15 * 60,
        downTTL: TimeInterval = 2 * 60,
        prober: @escaping Prober = TCPReachability.canConnect,
        networkReader: @escaping NetworkReader = LocalNetworkFingerprint.current,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.probeTimeout = probeTimeout
        self.upTTL = upTTL
        self.downTTL = downTTL
        self.prober = prober
        self.networkReader = networkReader
        self.now = now
    }

    /// True when the primary endpoint should be attempted first.
    func prefersPrimary(_ primaryBaseURL: String) async -> Bool {
        guard let target = EndpointTarget(primaryBaseURL) else { return false }
        let network = networkReader(target.host)
        guard case .candidate(let fingerprint) = network else {
            routeLog.info("🧭 \(target.key, privacy: .public): not on its subnet, using fallback")
            return false
        }
        if let verdict = verdicts[target.key], isFresh(verdict, network: fingerprint) {
            return verdict.reachable
        }
        if let running = inflight[target.key] {
            return await running.value
        }
        let prober = self.prober
        let timeout = probeTimeout
        let task = Task { await prober(target.host, target.port, timeout) }
        inflight[target.key] = task
        let started = now()
        let reachable = await task.value
        inflight[target.key] = nil
        verdicts[target.key] = Verdict(reachable: reachable, network: fingerprint, decidedAt: now())
        let ms = Int(now().timeIntervalSince(started) * 1000)
        routeLog.info("🧭 \(target.key, privacy: .public): probe \(reachable ? "reachable" : "unreachable", privacy: .public) in \(ms)ms")
        return reachable
    }

    /// Starts (or reuses) the verdict in the background so the first request
    /// does not wait for the probe.
    nonisolated func prewarm(_ primaryBaseURL: String) {
        Task { _ = await prefersPrimary(primaryBaseURL) }
    }

    /// A real request to the primary failed; skip it on this network for
    /// `downTTL`.
    func reportFailure(_ primaryBaseURL: String) {
        guard let target = EndpointTarget(primaryBaseURL),
              case .candidate(let fingerprint) = networkReader(target.host) else { return }
        verdicts[target.key] = Verdict(reachable: false, network: fingerprint, decidedAt: now())
        routeLog.info("🧭 \(target.key, privacy: .public): request failed, demoted for \(Int(self.downTTL))s")
    }

    func verdict(for primaryBaseURL: String) -> Verdict? {
        EndpointTarget(primaryBaseURL).flatMap { verdicts[$0.key] }
    }

    private func isFresh(_ verdict: Verdict, network: String) -> Bool {
        guard verdict.network == network else { return false }
        let ttl = verdict.reachable ? upTTL : downTTL
        return now().timeIntervalSince(verdict.decidedAt) < ttl
    }
}

// MARK: - Endpoint target

struct EndpointTarget: Equatable {
    let host: String
    let port: UInt16

    var key: String { "\(host):\(port)" }

    init?(_ baseURL: String) {
        guard let components = URLComponents(string: baseURL),
              let scheme = components.scheme?.lowercased(),
              let host = components.host, !host.isEmpty else { return nil }
        let defaultPort: UInt16 = scheme == "https" ? 443 : 80
        self.host = host
        self.port = components.port.flatMap { UInt16(exactly: $0) } ?? defaultPort
    }
}

// MARK: - Local network fingerprint

/// What the phone's interfaces say about reaching a host locally.
enum LocalNetworkFingerprint: Equatable, Sendable {
    /// The host may be reachable; the string identifies the current network
    /// (used to invalidate cached probe verdicts when it changes).
    case candidate(String)
    /// The host is a literal IPv4 address outside every local subnet, so it
    /// cannot be on this network. No probe is needed.
    case offSubnet

    struct Interface: Equatable, Sendable {
        let name: String
        let address: UInt32   // host byte order
        let netmask: UInt32   // host byte order
    }

    static func current(host: String) -> LocalNetworkFingerprint {
        evaluate(host: host, interfaces: activeIPv4Interfaces())
    }

    static func evaluate(host: String, interfaces: [Interface]) -> LocalNetworkFingerprint {
        if let target = ipv4(host) {
            let matching = interfaces.filter {
                $0.netmask != 0 && ($0.address & $0.netmask) == (target & $0.netmask)
            }
            guard !matching.isEmpty else { return .offSubnet }
            return .candidate(describe(matching))
        }
        // Hostnames (`pc.local`, `pc`) cannot be subnet-checked without DNS;
        // key the cached verdict on the whole interface set instead.
        return .candidate(describe(interfaces))
    }

    static func ipv4(_ string: String) -> UInt32? {
        var address = in_addr()
        guard inet_pton(AF_INET, string, &address) == 1 else { return nil }
        return UInt32(bigEndian: address.s_addr)
    }

    private static func describe(_ interfaces: [Interface]) -> String {
        interfaces
            .map { "\($0.name)=\(format($0.address))/\(format($0.netmask))" }
            .sorted()
            .joined(separator: ",")
    }

    private static func format(_ value: UInt32) -> String {
        [24, 16, 8, 0].map { String((value >> UInt32($0)) & 0xFF) }.joined(separator: ".")
    }

    static func activeIPv4Interfaces() -> [Interface] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [] }
        defer { freeifaddrs(head) }
        var result: [Interface] = []
        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let entry = pointer.pointee
            let flags = Int32(entry.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_RUNNING != 0, flags & IFF_LOOPBACK == 0,
                  let addr = entry.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET),
                  let mask = entry.ifa_netmask else { continue }
            let address = addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
                UInt32(bigEndian: $0.pointee.sin_addr.s_addr)
            }
            let netmask = mask.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
                UInt32(bigEndian: $0.pointee.sin_addr.s_addr)
            }
            result.append(Interface(name: String(cString: entry.ifa_name), address: address, netmask: netmask))
        }
        return result
    }
}

// MARK: - TCP reachability

enum TCPReachability {
    /// Opens (and immediately closes) a TCP connection. Cellular is excluded:
    /// the primary is meant to be the LAN path.
    @Sendable
    static func canConnect(host: String, port: UInt16, timeout: TimeInterval) async -> Bool {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else { return false }
        let parameters = NWParameters.tcp
        parameters.prohibitedInterfaceTypes = [.cellular]
        let connection = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: parameters)
        let once = ResumeOnce()
        let queue = DispatchQueue(label: "com.fonos.endpoint-probe")
        return await withCheckedContinuation { continuation in
            let finish: @Sendable (Bool) -> Void = { result in
                guard once.claim() else { return }
                connection.cancel()
                continuation.resume(returning: result)
            }
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready: finish(true)
                // `.waiting` means no usable path (or local network access
                // denied); treat as unreachable rather than waiting it out.
                case .failed, .waiting, .cancelled: finish(false)
                default: break
                }
            }
            connection.start(queue: queue)
            queue.asyncAfter(deadline: .now() + timeout) { finish(false) }
        }
    }

    private final class ResumeOnce: @unchecked Sendable {
        private let lock = NSLock()
        private var claimed = false
        func claim() -> Bool {
            lock.lock(); defer { lock.unlock() }
            if claimed { return false }
            claimed = true
            return true
        }
    }
}

// MARK: - Failover providers

/// Runs an operation against the primary endpoint when the router prefers
/// it, and against the fallback otherwise or after a primary failure.
struct EndpointFailover: Sendable {
    let primaryBaseURL: String
    let router: EndpointRouter

    func run<Provider>(
        primary: Provider,
        fallback: Provider,
        _ operation: (Provider) async throws -> String
    ) async throws -> String {
        if await router.prefersPrimary(primaryBaseURL) {
            do {
                return try await operation(primary)
            } catch {
                if error is CancellationError || Task.isCancelled { throw error }
                routeLog.info("🧭 primary failed (\(error.localizedDescription, privacy: .public)); retrying via fallback")
                await router.reportFailure(primaryBaseURL)
            }
        }
        try Task.checkCancellation()
        return try await operation(fallback)
    }
}

/// STT provider that prefers a LAN endpoint and falls back to a public one.
struct FailoverSTT: STTProvider {
    let primary: any STTProvider
    let fallback: any STTProvider
    let failover: EndpointFailover

    init(
        primary: any STTProvider,
        fallback: any STTProvider,
        primaryBaseURL: String,
        router: EndpointRouter = .shared
    ) {
        self.primary = primary
        self.fallback = fallback
        self.failover = EndpointFailover(primaryBaseURL: primaryBaseURL, router: router)
        router.prewarm(primaryBaseURL)
    }

    func transcribe(audioData: Data, language: String?) async throws -> String {
        try await failover.run(primary: primary, fallback: fallback) {
            try await $0.transcribe(audioData: audioData, language: language)
        }
    }

    func transcribe(
        audioData: Data,
        language: String?,
        vocabulary: [String],
        promptHint: String
    ) async throws -> String {
        try await failover.run(primary: primary, fallback: fallback) {
            try await $0.transcribe(
                audioData: audioData, language: language,
                vocabulary: vocabulary, promptHint: promptHint
            )
        }
    }

    func transcribe(
        audioData: Data,
        language: String?,
        vocabulary: [String],
        promptHint: String,
        temperature: Double
    ) async throws -> String {
        try await failover.run(primary: primary, fallback: fallback) {
            try await $0.transcribe(
                audioData: audioData, language: language,
                vocabulary: vocabulary, promptHint: promptHint,
                temperature: temperature
            )
        }
    }
}

/// LLM provider that prefers a LAN endpoint and falls back to a public one.
struct FailoverLLMProvider: VoiceWorkflowLLMProvider {
    let primary: any VoiceWorkflowLLMProvider
    let fallback: any VoiceWorkflowLLMProvider
    let failover: EndpointFailover

    init(
        primary: any VoiceWorkflowLLMProvider,
        fallback: any VoiceWorkflowLLMProvider,
        primaryBaseURL: String,
        router: EndpointRouter = .shared
    ) {
        self.primary = primary
        self.fallback = fallback
        self.failover = EndpointFailover(primaryBaseURL: primaryBaseURL, router: router)
        router.prewarm(primaryBaseURL)
    }

    func process(text: String, configuration: LLMRequestConfiguration) async throws -> String {
        try await failover.run(primary: primary, fallback: fallback) {
            try await $0.process(text: text, configuration: configuration)
        }
    }
}
