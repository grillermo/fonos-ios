import DictusModels
import SwiftUI

/// Holds the unexpected exit found at launch until the user has seen it.
@MainActor
final class UnexpectedExitNotice: ObservableObject {
    static let shared = UnexpectedExitNotice()
    @Published var pending: UnexpectedExit?
}

private struct UnexpectedExitAlert: ViewModifier {
    @ObservedObject private var notice = UnexpectedExitNotice.shared

    func body(content: Content) -> some View {
        content.alert(
            "Fonos was stopped last time",
            isPresented: Binding(
                get: { notice.pending != nil },
                set: { if !$0 { notice.pending = nil } }
            ),
            presenting: notice.pending
        ) { _ in
            Button("OK", role: .cancel) { notice.pending = nil }
        } message: { exit in
            Text(exit.summary)
        }
    }
}

extension View {
    /// Shows, once, what the previous launch was doing when iOS stopped it.
    func unexpectedExitAlert() -> some View {
        modifier(UnexpectedExitAlert())
    }
}

/// Settings › Models › On-device models: download every Dictus model, pick one
/// for dictation, and see memory use and any kills.
struct OnDeviceModelsView: View {
    @Binding var config: AppConfig
    @ObservedObject private var models = OnDeviceModels.shared
    @State private var exits: [UnexpectedExit] = []
    @State private var reports: [ExitCountsReport] = []
    @State private var runs: [OnDeviceRun] = []
    @State private var busy: Set<String> = []
    @State private var errorMessage: String?

    var body: some View {
        List {
            memorySection
            if !exits.isEmpty { exitsSection }
            modelsSection
            metricKitSection
            Section {
                NavigationLink("Dictus download log") {
                    ScrollView {
                        Text(OnDeviceModels.debugLog())
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                            .padding()
                    }
                }
            } footer: {
                Text("To confirm a memory kill: Settings › Privacy & Security › Analytics & Improvements › Analytics Data, then look for JetsamEvent files from the time of the kill.")
            }
        }
        .navigationTitle("On-device models")
        .onAppear(perform: reload)
        .alert("Model error", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    // MARK: - Sections

    private var memorySection: some View {
        Section("Memory now") {
            TimelineView(.periodic(from: .now, by: 2)) { _ in
                let snapshot = ProcessMemory.snapshot()
                LabeledContent("Footprint", value: "\(snapshot.footprintMB) MB")
                LabeledContent("Left before iOS kills Fonos", value: "\(snapshot.availableMB) MB")
                LabeledContent("Loaded model", value: models.loadedModelID ?? "none")
            }
        }
    }

    private var exitsSection: some View {
        Section {
            ForEach(exits) { exit in
                VStack(alignment: .leading, spacing: 4) {
                    Text(exit.breadcrumb.updatedAt.formatted(date: .abbreviated, time: .standard))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(exit.summary)
                }
            }
            Button("Clear", role: .destructive) {
                TerminationWatch.shared.clearExits()
                reload()
            }
        } header: {
            Text("Stopped during model work")
        }
    }

    private var modelsSection: some View {
        Section {
            ForEach(models.catalog) { model in
                modelRow(model)
            }
        } header: {
            Text("Dictus models")
        } footer: {
            Text("A failed download keeps what it has and resumes from there. The first load after a download compiles the model for the Neural Engine, which can take minutes.")
        }
    }

    private var metricKitSection: some View {
        Section {
            if reports.isEmpty {
                Text("No report yet. iOS sends one about once a day.")
                    .foregroundStyle(.secondary)
            }
            ForEach(reports) { report in
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(report.periodStart.formatted(date: .abbreviated, time: .shortened)) – \(report.periodEnd.formatted(date: .omitted, time: .shortened))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("Memory kills: \(report.foregroundMemoryLimit) foreground, \(report.backgroundMemoryLimit) background")
                    Text("Background pressure: \(report.backgroundMemoryPressure) · abnormal: \(report.foregroundAbnormal + report.backgroundAbnormal) · watchdog: \(report.foregroundWatchdog)")
                        .font(.caption)
                }
            }
        } header: {
            Text("iOS exit reports (MetricKit)")
        }
    }

    // MARK: - Rows

    @ViewBuilder
    private func modelRow(_ model: OnDeviceModel) -> some View {
        let status = models.status(of: model.id)
        let selected = config.sttProfile == ModelProfile.onDevice(modelID: model.id, displayName: model.displayName).id
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(model.displayName).font(.headline)
                if model.isDeprecated {
                    Text("legacy").font(.caption2).padding(.horizontal, 4)
                        .overlay(Capsule().stroke(.secondary))
                }
                Spacer()
                if selected { Image(systemName: "checkmark.circle.fill").foregroundStyle(.green) }
            }
            Text("\(model.engineName) · \(ByteCountFormatter.string(fromByteCount: model.sizeBytes, countStyle: .file))")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(statusText(status)).font(.caption)
            if let run = runs.first(where: { $0.modelID == model.id }) {
                Text(String(format: "Last run: %.1fs audio, %.1f× real time, load %d ms, peak %d MB",
                            run.audioSeconds, run.realTimeFactor, run.loadMilliseconds, run.peakFootprintMB))
                    .font(.caption)
            }
            HStack {
                switch status {
                case .notDownloaded, .failed:
                    Button("Download") { install(model) }
                case .downloading, .compiling:
                    ProgressView()
                case .ready:
                    Button("Use for dictation") { select(model) }.disabled(selected)
                    Button("Load now") { load(model) }
                    Button("Delete", role: .destructive) { delete(model) }
                }
            }
            .buttonStyle(.bordered)
            .disabled(busy.contains(model.id))
        }
        .padding(.vertical, 4)
    }

    private func statusText(_ status: OnDeviceModelStatus) -> String {
        switch status {
        case .notDownloaded: "Not downloaded"
        case let .downloading(fraction, downloaded, total):
            "Downloading \(Int(fraction * 100))% (\(downloaded) of \(total) MB)"
        case .compiling: "Compiling for the Neural Engine…"
        case .ready: "Ready"
        case .failed(let message): "Failed: \(message)"
        }
    }

    // MARK: - Actions

    private func reload() {
        exits = TerminationWatch.shared.recordedExits()
        reports = ExitMetricsReporter.shared.reports()
        runs = OnDeviceRunLog.shared.runs()
    }

    private func install(_ model: OnDeviceModel) {
        run(model) {
            try await TerminationWatch.shared.during(.installing, modelID: model.id) {
                try await models.download(model.id)
            }
        }
    }

    private func load(_ model: OnDeviceModel) {
        run(model) {
            TerminationWatch.shared.resetPeak()
            _ = try await TerminationWatch.shared.during(.loading, modelID: model.id) {
                try await models.load(model.id)
            }
        }
    }

    private func delete(_ model: OnDeviceModel) {
        do {
            try models.delete(model.id)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func select(_ model: OnDeviceModel) {
        let profile = ModelProfile.onDevice(modelID: model.id, displayName: model.displayName)
        if let index = config.modelProfiles.firstIndex(where: { $0.id == profile.id }) {
            config.modelProfiles[index] = profile
        } else {
            config.modelProfiles.append(profile)
        }
        config.sttProfile = profile.id
    }

    private func run(_ model: OnDeviceModel, _ work: @escaping @MainActor () async throws -> Void) {
        busy.insert(model.id)
        Task { @MainActor in
            defer {
                busy.remove(model.id)
                reload()
            }
            do {
                try await work()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}
