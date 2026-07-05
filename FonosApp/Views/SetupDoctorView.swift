import SwiftUI
import AVFAudio
import Speech

/// Settings › General › Setup Doctor — runs every diagnostic and offers
/// one-tap fixes (P1-3).
struct SetupDoctorView: View {
    let config: AppConfig

    @StateObject private var doctor = SetupDoctor()

    private let bg = Color(hex: "#1a1917")
    private let textPrimary = Color(hex: "#fafaf9")
    private let textDim = Color(hex: "#fafaf9").opacity(0.5)
    private let amber = Color(hex: "#fbbf24")

    var body: some View {
        ZStack {
            bg.ignoresSafeArea()

            List {
                Section {
                    ForEach(doctor.checks) { check in
                        checkRow(check)
                            .listRowBackground(Color.white.opacity(0.02))
                    }
                } footer: {
                    if doctor.isRunning {
                        Text("Running checks…")
                    }
                }

                Section {
                    Button {
                        Task { await doctor.runAll(config: config) }
                    } label: {
                        Label("Run Again", systemImage: "arrow.clockwise")
                            .foregroundColor(amber)
                    }
                    .listRowBackground(Color.white.opacity(0.02))
                }
            }
            .scrollContentBackground(.hidden)
        }
        .navigationTitle("Setup Doctor")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await doctor.runAll(config: config)
        }
    }

    // MARK: - Row

    private func checkRow(_ check: DoctorCheck) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                statusIcon(check.status)
                Text(check.title)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundColor(textPrimary)
                Spacer()
            }
            Text(check.detail)
                .font(.system(size: 13))
                .foregroundColor(textDim)
                .fixedSize(horizontal: false, vertical: true)

            if let fix = check.fix {
                Button(fixLabel(fix)) {
                    applyFix(fix)
                }
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(amber)
                .buttonStyle(.borderless)
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func statusIcon(_ status: DoctorCheck.Status) -> some View {
        switch status {
        case .pass:
            Image(systemName: "checkmark.circle.fill")
                .foregroundColor(Color(hex: "#86efac"))
        case .warn:
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(amber)
        case .fail:
            Image(systemName: "xmark.circle.fill")
                .foregroundColor(Color(hex: "#ef4444"))
        }
    }

    // MARK: - Fixes

    private func fixLabel(_ fix: DoctorCheck.Fix) -> String {
        switch fix {
        case .openSettings:            return String(localized: "Open Settings")
        case .requestMicPermission:    return String(localized: "Request Permission")
        case .requestSpeechPermission: return String(localized: "Request Permission")
        }
    }

    private func applyFix(_ fix: DoctorCheck.Fix) {
        switch fix {
        case .openSettings:
            if let url = URL(string: UIApplication.openSettingsURLString) {
                UIApplication.shared.open(url)
            }
        case .requestMicPermission:
            AVAudioApplication.requestRecordPermission { _ in
                Task { @MainActor in
                    await doctor.runAll(config: config)
                }
            }
        case .requestSpeechPermission:
            SFSpeechRecognizer.requestAuthorization { _ in
                Task { @MainActor in
                    await doctor.runAll(config: config)
                }
            }
        }
    }
}

#Preview {
    NavigationStack {
        SetupDoctorView(config: AppConfig())
    }
    .preferredColorScheme(.dark)
}
