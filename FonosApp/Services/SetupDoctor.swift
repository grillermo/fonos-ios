import Foundation
import AVFAudio
import Speech
import UIKit

// MARK: - DoctorCheck

/// One diagnostics row on the Setup Doctor page.
struct DoctorCheck: Identifiable, Equatable {
    enum Status: Equatable {
        case pass
        case warn
        case fail
    }

    enum Fix: Equatable {
        case openSettings
        case requestMicPermission
        case requestSpeechPermission
    }

    let id: String
    let title: String
    var status: Status
    var detail: String
    var fix: Fix?
}

// MARK: - SetupDoctor

/// P1-3: diagnoses the opaque iOS failure surface in one page — permissions,
/// keyboard setup, App Group IPC plumbing, endpoint reachability, and config
/// lint — with one-tap fixes where the system allows them.
@MainActor
final class SetupDoctor: ObservableObject {

    @Published var checks: [DoctorCheck] = []
    @Published var isRunning = false

    private let appGroupID = KeyboardIPC.appGroupID

    // MARK: - Run

    func runAll(config: AppConfig, vocabStore: VocabStore = VocabStore()) async {
        isRunning = true
        var results: [DoctorCheck] = []

        results.append(micCheck())
        results.append(speechCheck())
        results.append(keyboardCheck())
        results.append(appGroupCheck())
        results.append(contentsOf: await endpointChecks(config: config))
        results.append(lintCheck(config: config, vocabStore: vocabStore))

        checks = results
        isRunning = false
    }

    // MARK: - Individual checks

    private func micCheck() -> DoctorCheck {
        switch AVAudioApplication.shared.recordPermission {
        case .granted:
            return DoctorCheck(id: "mic", title: String(localized: "Microphone permission"),
                               status: .pass, detail: String(localized: "Granted."))
        case .undetermined:
            return DoctorCheck(id: "mic", title: String(localized: "Microphone permission"),
                               status: .warn, detail: String(localized: "Not requested yet — recording will prompt."),
                               fix: .requestMicPermission)
        case .denied:
            return DoctorCheck(id: "mic", title: String(localized: "Microphone permission"),
                               status: .fail, detail: String(localized: "Denied. Dictation cannot record."),
                               fix: .openSettings)
        @unknown default:
            return DoctorCheck(id: "mic", title: String(localized: "Microphone permission"),
                               status: .warn, detail: String(localized: "Unknown state."), fix: .openSettings)
        }
    }

    private func speechCheck() -> DoctorCheck {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized:
            return DoctorCheck(id: "speech", title: String(localized: "Speech recognition permission"),
                               status: .pass, detail: String(localized: "Granted."))
        case .notDetermined:
            return DoctorCheck(id: "speech", title: String(localized: "Speech recognition permission"),
                               status: .warn, detail: String(localized: "Not requested yet — Apple STT will prompt."),
                               fix: .requestSpeechPermission)
        case .denied, .restricted:
            return DoctorCheck(id: "speech", title: String(localized: "Speech recognition permission"),
                               status: .fail, detail: String(localized: "Denied. On-device Apple STT is unavailable."),
                               fix: .openSettings)
        @unknown default:
            return DoctorCheck(id: "speech", title: String(localized: "Speech recognition permission"),
                               status: .warn, detail: String(localized: "Unknown state."), fix: .openSettings)
        }
    }

    private func keyboardCheck() -> DoctorCheck {
        // iOS has no public API that tells an app whether its custom keyboard
        // extension is enabled or has Full Access. In particular, do not read
        // the system-owned `AppleKeyboards` defaults key: required-reason
        // UserDefaults access permits only values written by this app/group.
        return DoctorCheck(
            id: "keyboard",
            title: String(localized: "Fonos keyboard setup"),
            status: .warn,
            detail: String(
                localized: """
                iOS cannot report keyboard enablement to Fonos. \
                Confirm that Fonos is added in Settings → General → Keyboard → Keyboards and that Full Access is enabled.
                """
            ),
            fix: .openSettings
        )
    }

    private func appGroupCheck() -> DoctorCheck {
        if FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupID) != nil {
            return DoctorCheck(id: "appgroup", title: String(localized: "Keyboard ↔ app bridge (App Group)"),
                               status: .pass,
                               detail: String(localized: "App Group container is accessible; keyboard IPC can work."))
        }
        return DoctorCheck(
            id: "appgroup",
            title: String(localized: "Keyboard ↔ app bridge (App Group)"),
            status: .fail,
            detail: String(
                localized: """
                App Group \(appGroupID) is not accessible — keyboard dictation cannot reach the recorder. \
                Check entitlements/provisioning.
                """
            )
        )
    }

    private func endpointChecks(config: AppConfig) async -> [DoctorCheck] {
        let urls = Self.endpointsToCheck(config: config)
        guard !urls.isEmpty else {
            return [DoctorCheck(id: "endpoints", title: String(localized: "Model endpoints"),
                                status: .pass,
                                detail: String(localized: "No custom endpoints configured (Apple on-device STT needs none)."))]
        }
        var results: [DoctorCheck] = []
        for url in urls {
            let reachable = await Self.isReachable(url)
            results.append(DoctorCheck(
                id: "endpoint-\(url.absoluteString)",
                title: "Endpoint \(url.absoluteString)",
                status: reachable ? .pass : .fail,
                detail: reachable
                    ? "Reachable."
                    : "Unreachable. Check that the server is running and this device is on the same network."
            ))
        }
        return results
    }

    private func lintCheck(config: AppConfig, vocabStore: VocabStore) -> DoctorCheck {
        let issues = Self.lintConfig(config, vocabStore: vocabStore)
        if issues.isEmpty {
            return DoctorCheck(id: "lint", title: String(localized: "Configuration lint"),
                               status: .pass, detail: String(localized: "No dangling references."))
        }
        return DoctorCheck(id: "lint", title: String(localized: "Configuration lint"),
                           status: .warn, detail: issues.joined(separator: "\n"))
    }

    // MARK: - Pure logic (unit-tested)

    /// Dangling references: default STT/LLM profiles that don't exist, and
    /// vocab mounts pointing at deleted books.
    nonisolated static func lintConfig(_ config: AppConfig, vocabStore: VocabStore) -> [String] {
        var issues: [String] = []
        let profileIDs = Set(config.modelProfiles.map(\.id))

        let sttProfile = ModelProfileReference.normalized(config.sttProfile)
        let llmProfile = ModelProfileReference.normalized(config.llmProfile)
        if !sttProfile.isEmpty,
           sttProfile != ModelProfileReference.appleSpeech,
           !profileIDs.contains(sttProfile) {
            issues.append("Default STT profile '\(sttProfile)' does not exist.")
        }
        if !llmProfile.isEmpty && !profileIDs.contains(llmProfile) {
            issues.append("Default LLM profile '\(llmProfile)' does not exist.")
        }

        let bookIDs = Set(vocabStore.books.map(\.id))
        for (mountKey, ids) in vocabStore.allMounts() {
            for id in ids where !bookIDs.contains(id) {
                issues.append("Vocab mount '\(mountKey)' references missing book '\(id)'.")
            }
        }
        return issues
    }

    /// Base URLs of the profiles referenced by the default STT/LLM
    /// assignments, deduplicated, in reference order.
    nonisolated static func endpointsToCheck(config: AppConfig) -> [URL] {
        var seen: Set<String> = []
        var urls: [URL] = []
        for rawID in [config.sttProfile, config.llmProfile] {
            let id = ModelProfileReference.normalized(rawID)
            guard !id.isEmpty, id != ModelProfileReference.appleSpeech else { continue }
            guard let profile = config.modelProfiles.first(where: { $0.id == id }) else {
                continue
            }
            guard let baseURL = profile.portableBaseURL, !baseURL.isEmpty,
                  let url = URL(string: baseURL),
                  let scheme = url.scheme?.lowercased(),
                  scheme == "http" || scheme == "https",
                  url.host?.isEmpty == false,
                  seen.insert(baseURL).inserted else { continue }
            urls.append(url)
        }
        return urls
    }

    /// Any HTTP response (even an error status) proves the host is up;
    /// only transport failures count as unreachable.
    nonisolated static func isReachable(_ url: URL, session: URLSession = .shared) async -> Bool {
        var request = URLRequest(url: url)
        request.timeoutInterval = 5
        request.httpMethod = "GET"
        do {
            _ = try await session.data(for: request)
            return true
        } catch {
            return false
        }
    }
}
