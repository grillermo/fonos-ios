import SwiftUI

enum FonosExternalLinks {
    private static func configuredHTTPSURL(forInfoKey key: String) -> URL? {
        guard let value = Bundle.main.object(forInfoDictionaryKey: key) as? String,
              let url = URL(string: value),
              url.scheme?.lowercased() == "https",
              url.host?.isEmpty == false else { return nil }
        return url
    }

    static var privacyPolicyURL: URL? {
        configuredHTTPSURL(forInfoKey: "FonosPrivacyPolicyURL")
    }

    static var supportURL: URL? {
        configuredHTTPSURL(forInfoKey: "FonosSupportURL")
    }
}

/// An always-available in-app privacy policy plus controls for withdrawing
/// remote-AI data-sharing permissions. A separately hosted HTTPS policy URL is
/// optional in the binary but remains required in App Store Connect.
struct PrivacySettingsView: View {
    let config: AppConfig

    @State private var consentRevision = 0

    private var consentedProfiles: [ModelProfile] {
        _ = consentRevision
        return config.modelProfiles.filter { RemoteAIConsentStore.isAuthorized(for: $0) }
    }

    var body: some View {
        List {
            Section("Privacy Policy") {
                policyRow(
                    title: "Data on this iPhone",
                    detail: """
                    Dictation history, notes, vocabulary, and configuration stay on this device unless you choose an output \
                    or network model that sends content elsewhere.
                    """
                )
                policyRow(
                    title: "Microphone and Apple Speech",
                    detail: """
                    Fonos records only for features you start and uses microphone and Speech permissions granted through iOS. \
                    During an explicit, time-limited Keyboard Ready session, microphone input stays active but idle buffers \
                    are discarded; Fonos retains audio only after you tap the keyboard microphone and releases it after that \
                    recipe finishes.
                    """
                )
                policyRow(
                    title: "Configured AI services",
                    detail: """
                    Before Fonos sends voice or text to a configured AI endpoint, it identifies the recipient and asks for \
                    your permission. The provider processes that content under its own terms and privacy policy.
                    """
                )
                policyRow(
                    title: "API keys",
                    detail: "API keys are stored in Apple Keychain. They are not stored in AppConfig or ordinary UserDefaults."
                )
                policyRow(
                    title: "Tracking",
                    detail: """
                    Fonos contains no third-party advertising or analytics SDK and does not track you across other companies’ \
                    apps or websites.
                    """
                )
                policyRow(
                    title: "Deleting data",
                    detail: """
                    You can delete history, notes, model profiles, and permissions in Fonos. \
                    Deleting the app removes app-local data managed by iOS. \
                    Contact a configured provider about data it may retain.
                    """
                )

                if let url = FonosExternalLinks.privacyPolicyURL {
                    Link(destination: url) {
                        Label("Open Published Privacy Policy", systemImage: "safari")
                    }
                }
            }

            Section {
                if consentedProfiles.isEmpty {
                    Text("No configured AI endpoint currently has permission to receive voice or text.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(consentedProfiles) { profile in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(profile.name)
                            if let identity = RemoteAIConsentStore.identity(for: profile) {
                                Text("\(identity.providerDisplayName) · \(identity.origin)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }

                    Button("Withdraw All Remote AI Permissions", role: .destructive) {
                        RemoteAIConsentStore.revokeAll()
                        consentRevision += 1
                    }
                }
            } header: {
                Text("Remote AI Permissions")
            } footer: {
                Text(
                    """
                    After withdrawal, network STT and LLM requests are blocked until you review and allow the endpoint again. \
                    Local Apple Speech remains available.
                    """
                )
            }

            if let url = FonosExternalLinks.supportURL {
                Section("Support") {
                    Link(destination: url) {
                        Label("Open Fonos Support", systemImage: "questionmark.circle")
                    }
                }
            }
        }
        .navigationTitle("Privacy")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func policyRow(title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.headline)
            Text(detail)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 3)
    }
}
