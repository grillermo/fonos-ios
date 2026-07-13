import SwiftUI
import UIKit
@preconcurrency import AVFoundation
import CoreImage.CIFilterBuiltins
import os

// MARK: - QR generation

enum QRCode {
    /// Render `string` as a crisp QR image (offline, CoreImage). Returns nil if
    /// the string is too large to encode.
    static func image(from string: String, scale: CGFloat = 10) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let context = CIContext()
        guard let cg = context.createCGImage(scaled, from: scaled.extent) else { return nil }
        return UIImage(cgImage: cg)
    }
}

// MARK: - QR scanner (AVFoundation)

/// AVFoundation metadata delegate. Kept off the main actor (the callback fires
/// on the queue we hand to setMetadataObjectsDelegate) and hops to main to
/// deliver the scan, so a @MainActor UIViewController never conforms directly.
final class QRScanCoordinator: NSObject, AVCaptureMetadataOutputObjectsDelegate, Sendable {
    private let onScan: @Sendable (String) -> Void
    private let handled = OSAllocatedUnfairLock(initialState: false)

    init(onScan: @escaping @Sendable (String) -> Void) { self.onScan = onScan }

    func metadataOutput(_ output: AVCaptureMetadataOutput,
                        didOutput metadataObjects: [AVMetadataObject],
                        from connection: AVCaptureConnection) {
        guard let object = metadataObjects.first as? AVMetadataMachineReadableCodeObject,
              let value = object.stringValue else { return }
        let shouldDeliver = handled.withLock { handled in
            guard !handled else { return false }
            handled = true
            return true
        }
        guard shouldDeliver else { return }
        onScan(value)
    }
}

final class QRScannerViewController: UIViewController {
    var onScan: ((String) -> Void)?

    private let session = AVCaptureSession()
    /// AVFoundation's Objective-C session type is not annotated Sendable, but
    /// its blocking lifecycle calls are intentionally confined to this queue.
    private let sessionQueue = DispatchQueue(
        label: "com.fonos.ios.qr.session",
        qos: .userInitiated
    )
    private var previewLayer: AVCaptureVideoPreviewLayer?
    private var coordinator: QRScanCoordinator?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black

        guard let device = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input) else { return }
        session.addInput(input)

        let output = AVCaptureMetadataOutput()
        guard session.canAddOutput(output) else { return }
        session.addOutput(output)
        let coord = QRScanCoordinator { [weak self] value in
            DispatchQueue.main.async { self?.onScan?(value) }
        }
        coordinator = coord
        output.setMetadataObjectsDelegate(coord, queue: DispatchQueue(label: "com.fonos.ios.qr"))
        output.metadataObjectTypes = [.qr]

        let preview = AVCaptureVideoPreviewLayer(session: session)
        preview.videoGravity = .resizeAspectFill
        preview.frame = view.layer.bounds
        view.layer.addSublayer(preview)
        previewLayer = preview

        sessionQueue.async { [session] in
            guard !session.isRunning else { return }
            session.startRunning()
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        previewLayer?.frame = view.layer.bounds
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        sessionQueue.async { [session] in
            guard session.isRunning else { return }
            session.stopRunning()
        }
    }
}

struct QRScannerView: UIViewControllerRepresentable {
    var onScan: (String) -> Void

    func makeUIViewController(context: Context) -> QRScannerViewController {
        let vc = QRScannerViewController()
        vc.onScan = onScan
        return vc
    }

    func updateUIViewController(_ vc: QRScannerViewController, context: Context) {}
}

// MARK: - Import preview

/// Shown before applying any imported bundle. Untrusted input is never applied
/// without this confirmation.
struct ConfigImportPreviewView: View {
    let summary: ScenarioImportSummary
    let onImport: () -> Void
    let onCancel: () -> Void

    var body: some View {
        NavigationStack {
            ZStack {
                Color(hex: "#1a1917").ignoresSafeArea()
                List {
                    Section {
                        if summary.importedProfiles > 0 {
                            row("Model profiles", summary.importedProfiles)
                            if summary.profilesNeedingKeys > 0 {
                                Text("\(summary.profilesNeedingKeys) need an API key — you'll enter these after import.")
                                    .font(.system(size: 12))
                                    .foregroundColor(Color(hex: "#fbbf24"))
                            }
                        }
                        if summary.sttProfileSet || summary.llmProfileSet {
                            Text("Default model assignments")
                        }
                        if summary.dictationApplied { Text("Dictation defaults") }
                        if summary.vocabBooksImported > 0 { row("Vocab books", summary.vocabBooksImported) }
                        if summary.importedWorkflows > 0 {
                            row("Voice recipes", summary.importedWorkflows)
                        }
                        if summary.importedWidgets > 0 {
                            row("Reusable components", summary.importedWidgets)
                        }
                    } header: {
                        Text(summary.name.isEmpty ? "Shared config" : summary.name)
                    } footer: {
                        Text("Existing items with the same id are updated; nothing else is removed.")
                    }

                    if summary.unsupportedWorkflows > 0 || summary.unsupportedWidgets > 0 {
                        Section("iPhone compatibility") {
                            Label {
                                Text(
                                    """
                                    \(summary.unsupportedWorkflows) recipe entries and \
                                    \(summary.unsupportedWidgets) component entries are unsupported or invalid. \
                                    Decodable definitions are kept for sharing, but cannot run on this iPhone.
                                    """
                                )
                                .font(.system(size: 12))
                            } icon: {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundColor(.orange)
                            }
                        }
                    }

                    if summary.noRunnableWorkflow {
                        Section("Active voice recipe") {
                            Label {
                                Text(
                                    """
                                    No runnable microphone recipe remains after this import. \
                                    The active recipe will be cleared; imported definitions are still retained for editing or sharing.
                                    """
                                )
                                .font(.system(size: 12))
                            } icon: {
                                Image(systemName: "mic.slash.fill")
                                    .foregroundColor(.red)
                            }
                        }
                    } else if summary.activeWorkflowAdjusted {
                        Section("Active voice recipe") {
                            Label {
                                Text(
                                    """
                                    The requested recipe cannot run on this iPhone. \
                                    Fonos will use \(workflowSelectionLabel(summary)) instead.
                                    """
                                )
                                .font(.system(size: 12))
                            } icon: {
                                Image(systemName: "arrow.triangle.branch")
                                    .foregroundColor(Color(hex: "#fbbf24"))
                            }
                        }
                    }

                    if summary.adaptedWorkflows > 0 {
                        Section("Surface adaptation") {
                            Label {
                                Text(
                                    """
                                    \(summary.adaptedWorkflows) desktop Insert recipes will return their final text to the current \
                                    iPhone surface; the keyboard inserts it explicitly.
                                    """
                                )
                                .font(.system(size: 12))
                            } icon: {
                                Image(systemName: "iphone.and.arrow.forward")
                                    .foregroundColor(Color(hex: "#fbbf24"))
                            }
                        }
                    }

                    if !summary.skippedSections.isEmpty {
                        Section {
                            Text("Skipped (not applicable on iOS): \(summary.skippedSections.joined(separator: ", "))")
                                .font(.system(size: 12))
                                .foregroundColor(.secondary)
                        }
                    }
                }
                .scrollContentBackground(.hidden)
            }
            .navigationTitle("Import Config")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { onCancel() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Import") { onImport() }
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    private func row(_ label: String, _ count: Int) -> some View {
        HStack {
            Text(label)
            Spacer()
            Text("\(count)").foregroundColor(.secondary)
        }
    }

    private func workflowSelectionLabel(_ summary: ScenarioImportSummary) -> String {
        if summary.selectedWorkflowName.isEmpty { return summary.selectedWorkflowID }
        return "\(summary.selectedWorkflowName) (\(summary.selectedWorkflowID))"
    }
}

// MARK: - Export sheet

/// Export a bundle as a QR + link + text (keyless) or copyable text (with keys).
struct ConfigExportSheet: View {
    let bundleJSON: Data
    let name: String

    @Environment(\.dismiss) private var dismiss
    @State private var includeKeys = false
    @State private var copied = false

    private var keylessURL: String {
        ConfigBundleCodec.encodeURL(bundleJSON: bundleJSON).absoluteString
    }

    private var qrImage: UIImage? {
        guard ConfigBundleCodec.fitsQR(bundleJSON: bundleJSON) else { return nil }
        return QRCode.image(from: keylessURL)
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Color(hex: "#1a1917").ignoresSafeArea()
                ScrollView {
                    VStack(spacing: 20) {
                        Toggle("Include API keys", isOn: $includeKeys)
                            .tint(Color(hex: "#fbbf24"))
                            .padding(.horizontal, 20)

                        if includeKeys {
                            warning(
                                """
                                Includes your API keys — share only with your own devices. \
                                This bundle is copyable text only (no QR/link) to avoid leaking keys.
                                """
                            )
                            copyButton("Copy config text (with keys)") {
                                UIPasteboard.general.string = prettyText(injectingKeys: true)
                            }
                        } else {
                            if let qrImage {
                                Image(uiImage: qrImage)
                                    .interpolation(.none)
                                    .resizable()
                                    .scaledToFit()
                                    .frame(maxWidth: 260)
                                    .padding(12)
                                    .background(Color.white)
                                    .cornerRadius(12)
                                Text("Scan with the other device's camera.")
                                    .font(.system(size: 12))
                                    .foregroundColor(.secondary)
                            } else {
                                warning("This config is too large for a QR code — use Copy Link or Copy Text instead.")
                            }
                            copyButton("Copy Link") { UIPasteboard.general.string = keylessURL }
                            copyButton("Copy Text") { UIPasteboard.general.string = prettyText(injectingKeys: false) }
                        }

                        if copied {
                            Text("Copied!")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundColor(Color(hex: "#86efac"))
                        }
                    }
                    .padding(.vertical, 24)
                }
            }
            .navigationTitle(name.isEmpty ? "Export" : name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    private func prettyText(injectingKeys: Bool) -> String {
        let data = injectingKeys ? ConfigBundleExporter.injectingKeys(into: bundleJSON) : bundleJSON
        guard let obj = try? JSONSerialization.jsonObject(with: data),
              let pretty = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]),
              let s = String(data: pretty, encoding: .utf8) else {
            return String(data: data, encoding: .utf8) ?? "{}"
        }
        return s
    }

    private func warning(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundColor(Color(hex: "#fbbf24"))
            .multilineTextAlignment(.center)
            .padding(.horizontal, 24)
    }

    private func copyButton(_ title: String, _ action: @escaping () -> Void) -> some View {
        Button {
            action()
            withAnimation { copied = true }
        } label: {
            Text(title)
                .font(.system(size: 15, weight: .medium))
                .foregroundColor(Color(hex: "#1a1917"))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(RoundedRectangle(cornerRadius: 12).fill(Color(hex: "#fbbf24")))
                .padding(.horizontal, 20)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Config sets manager

struct ConfigSetsView: View {
    @Binding var config: AppConfig

    private let store = ConfigSetStore()
    private let vocabStore = VocabStore()

    @State private var sets: [ConfigSet] = []
    @State private var showScanner = false
    @State private var showSaveDialog = false
    @State private var newSetName = ""
    @State private var exportBundle: ExportPayload?
    @State private var pendingImport: PendingImport?
    @State private var importError: String?

    private struct ExportPayload: Identifiable { let id = UUID(); let json: Data; let name: String }
    private struct PendingImport: Identifiable { let id = UUID(); let data: Data; let summary: ScenarioImportSummary }

    var body: some View {
        ZStack {
            Color(hex: "#1a1917").ignoresSafeArea()
            List {
                if !sets.isEmpty {
                    Section("Saved config sets") {
                        ForEach(sets) { set in
                            setRow(set)
                        }
                        .onDelete { $0.forEach { store.delete(id: sets[$0].id) }; reload() }
                    }
                }

                Section {
                    Button { newSetName = ""; showSaveDialog = true } label: {
                        Label("Save current config as a set", systemImage: "square.and.arrow.down.on.square")
                    }
                    Button { exportCurrent() } label: {
                        Label("Export current config", systemImage: "square.and.arrow.up")
                    }
                } footer: {
                    Text(
                        """
                        A set bundles your model profiles, defaults, and vocab. \
                        Share it as a QR (keys stripped) or move it to your own device with keys.
                        """
                    )
                }

                Section {
                    Button { showScanner = true } label: {
                        Label("Scan a config QR", systemImage: "qrcode.viewfinder")
                    }
                    Button { pasteImport() } label: {
                        Label("Paste config", systemImage: "doc.on.clipboard")
                    }
                }
            }
            .scrollContentBackground(.hidden)
        }
        .navigationTitle("Config Sets")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: reload)
        .sheet(isPresented: $showScanner) {
            NavigationStack {
                QRScannerView { scanned in
                    showScanner = false
                    handleScanned(scanned)
                }
                .ignoresSafeArea()
                .navigationTitle("Scan Config QR")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { showScanner = false }
                    }
                }
            }
        }
        .sheet(item: $exportBundle) { payload in
            ConfigExportSheet(bundleJSON: payload.json, name: payload.name)
        }
        .sheet(item: $pendingImport) { pending in
            ConfigImportPreviewView(
                summary: pending.summary,
                onImport: { applyImport(pending.data); pendingImport = nil },
                onCancel: { pendingImport = nil }
            )
        }
        .alert("Couldn't read config", isPresented: .init(
            get: { importError != nil }, set: { if !$0 { importError = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(importError ?? "")
        }
        .alert("Save config set", isPresented: $showSaveDialog) {
            TextField("Name", text: $newSetName)
            Button("Save") { saveCurrent() }
            Button("Cancel", role: .cancel) {}
        }
    }

    private func setRow(_ set: ConfigSet) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(set.name).font(.system(size: 15, weight: .medium))
                Text(set.createdAt, style: .date).font(.system(size: 11)).foregroundColor(.secondary)
            }
            Spacer()
            Button("Apply") { applySet(set) }
                .buttonStyle(.borderless)
                .foregroundColor(Color(hex: "#fbbf24"))
            Button {
                exportBundle = ExportPayload(json: set.bundleJSON, name: set.name)
            } label: {
                Image(systemName: "square.and.arrow.up")
            }
            .buttonStyle(.borderless)
            .foregroundColor(Color(hex: "#fbbf24"))
        }
    }

    // MARK: Actions

    private func reload() { sets = store.sets }

    private func saveCurrent() {
        let name = newSetName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        let bundle = ConfigBundleExporter.bundleJSON(
            config: config, vocabStore: vocabStore, name: name, includeKeys: false)
        store.save(ConfigSet(id: UUID().uuidString, name: name, createdAt: Date(), bundleJSON: bundle))
        reload()
    }

    private func exportCurrent() {
        let bundle = ConfigBundleExporter.bundleJSON(
            config: config, vocabStore: vocabStore, name: "Current config", includeKeys: false)
        exportBundle = ExportPayload(json: bundle, name: "Current config")
    }

    private func applySet(_ set: ConfigSet) {
        handleData(set.bundleJSON)
    }

    private func pasteImport() {
        guard let text = UIPasteboard.general.string, !text.isEmpty else {
            importError = "The clipboard is empty."
            return
        }
        handleScanned(text)
    }

    private func handleScanned(_ scanned: String) {
        do {
            handleData(try ConfigBundleCodec.decode(scanned))
        } catch {
            importError = error.localizedDescription
        }
    }

    private func handleData(_ data: Data) {
        do {
            pendingImport = PendingImport(data: data, summary: try ScenarioImporter.preview(data: data))
        } catch {
            importError = error.localizedDescription
        }
    }

    private func applyImport(_ data: Data) {
        guard let (newConfig, _) = try? ScenarioImporter.apply(
            data: data, to: config, vocabStore: vocabStore) else { return }
        config = newConfig   // propagates through the SettingsView binding (saves + syncs Notes VM)
    }
}
