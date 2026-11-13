import Combine
import DictusCore
import Foundation

/// One row of the Dictus model catalogue, as Fonos sees it.
public struct OnDeviceModel: Identifiable, Equatable, Sendable {
    public let id: String
    public let displayName: String
    public let engineName: String
    public let sizeBytes: Int64
    public let isDeprecated: Bool
    public let firstPreparationSeconds: Int?
}

/// Download state of one model, flattened from Dictus's `ModelState`.
public enum OnDeviceModelStatus: Equatable, Sendable {
    case notDownloaded
    case downloading(fraction: Double, downloadedMB: Int, totalMB: Int)
    case compiling
    case ready
    case failed(String)
}

/// What one transcription produced and how long each part took.
public struct OnDeviceTranscription: Equatable, Sendable {
    public let text: String
    public let modelID: String
    public let audioSeconds: Double
    public let loadMilliseconds: Int
    public let transcribeMilliseconds: Int
    public var realTimeFactor: Double {
        transcribeMilliseconds > 0 ? audioSeconds * 1000 / Double(transcribeMilliseconds) : 0
    }
}

public enum OnDeviceModelsError: LocalizedError, Equatable {
    case unknownModel(String)
    case emptyAudio

    public var errorDescription: String? {
        switch self {
        case .unknownModel(let id): "Unknown on-device model '\(id)'."
        case .emptyAudio: "No audio to transcribe."
        }
    }
}

/// Public entry point to the vendored Dictus model code: catalogue, downloads
/// (resumable, verified, background URLSession) and the three engines.
/// Keeps at most one engine resident; loading another releases the first.
@MainActor
public final class OnDeviceModels: ObservableObject {
    public static let shared = OnDeviceModels()

    /// Every model Dictus knows, deprecated ones included, smallest first.
    public let catalog: [OnDeviceModel] = ModelInfo.allIncludingDeprecated
        .map {
            OnDeviceModel(
                id: $0.identifier,
                displayName: $0.displayName,
                engineName: $0.engine.displayName,
                sizeBytes: $0.sizeBytes,
                isDeprecated: $0.visibility == .deprecated,
                firstPreparationSeconds: $0.firstPreparationSeconds
            )
        }
        .sorted { $0.sizeBytes < $1.sizeBytes }

    public private(set) var loadedModelID: String?

    private let manager = ModelManager()
    private var engine: (any SpeechModelProtocol)?
    private var forwarding: AnyCancellable?

    private init() {
        forwarding = manager.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
    }

    public func status(of id: String) -> OnDeviceModelStatus {
        switch manager.modelStates[id] {
        case .downloading?:
            let bytes = manager.downloadByteInfo[id]
            return .downloading(
                fraction: Double(manager.downloadProgress[id] ?? 0),
                downloadedMB: bytes?.downloadedMB ?? 0,
                totalMB: bytes?.totalMB ?? 0
            )
        case .prewarming?: return .compiling
        case .ready?: return .ready
        case .error(let message)?: return .failed(message)
        case .notDownloaded?, nil:
            return manager.downloadedModels.contains(id) ? .ready : .notDownloaded
        }
    }

    /// Downloads, verifies and compiles the model. Safe to call again after a failure:
    /// completed files are kept and partial ones resume.
    public func download(_ id: String) async throws {
        guard ModelInfo.forIdentifier(id) != nil else { throw OnDeviceModelsError.unknownModel(id) }
        try await manager.downloadModel(id)
    }

    public func delete(_ id: String) throws {
        if loadedModelID == id { unload() }
        try manager.deleteModel(id)
    }

    /// Releases the resident engine so its memory can be reclaimed.
    public func unload() {
        engine = nil
        loadedModelID = nil
    }

    /// Loads the model into memory and runs one throwaway inference, so the
    /// Neural Engine's first-shape cost is paid here. Returns elapsed milliseconds.
    @discardableResult
    public func load(_ id: String) async throws -> Int {
        if loadedModelID == id, engine != nil { return 0 }
        guard let info = ModelInfo.forIdentifier(id) else { throw OnDeviceModelsError.unknownModel(id) }
        unload()
        let started = Date()
        let holder = "fonos-load:\(id)"
        try await DictationCoordinator.shared.acquireNeuralEngine(for: holder)
        defer { DictationCoordinator.shared.releaseNeuralEngine(from: holder) }
        let candidate: any SpeechModelProtocol
        switch info.engine {
        case .whisperKit: candidate = WhisperKitEngine()
        case .parakeet: candidate = ParakeetEngine()
        case .nemotron: candidate = NemotronEngine()
        }
        try await candidate.prepare(modelIdentifier: id)
        try await candidate.runWarmInference()
        engine = candidate
        loadedModelID = id
        return Int(Date().timeIntervalSince(started) * 1000)
    }

    /// Transcribes 16 kHz mono Float32 samples. `language` is a code like "es",
    /// or nil for auto-detect (Parakeet always auto-detects).
    public func transcribe(samples: [Float], modelID: String, language: String?) async throws -> OnDeviceTranscription {
        guard !samples.isEmpty else { throw OnDeviceModelsError.emptyAudio }
        let loadMilliseconds = try await load(modelID)
        guard let engine else { throw OnDeviceModelsError.unknownModel(modelID) }
        let started = Date()
        let result = try await engine.transcribe(audioSamples: samples, language: language)
        return OnDeviceTranscription(
            text: result.text,
            modelID: modelID,
            audioSeconds: Double(samples.count) / 16_000,
            loadMilliseconds: loadMilliseconds,
            transcribeMilliseconds: Int(Date().timeIntervalSince(started) * 1000)
        )
    }
}

// MARK: - App lifecycle hooks

extension OnDeviceModels {
    /// Forward `application(_:handleEventsForBackgroundURLSession:completionHandler:)`
    /// here. Returns false when the session is not the model downloader's, in which
    /// case the caller must call the handler itself.
    public static func handleBackgroundSessionEvents(
        identifier: String,
        completionHandler: @escaping () -> Void
    ) -> Bool {
        guard identifier == BackgroundModelDownloadService.sessionIdentifier else { return false }
        let box = CompletionBox(completionHandler)
        BackgroundModelDownloadService.shared.setBackgroundCompletionHandler { box.call() }
        return true
    }

    /// Dictus's own persistent debug log (downloads, compiles, prewarm timings).
    public static func debugLog() -> String {
        PersistentLog.read()
    }
}

/// Carries UIKit's non-Sendable completion handler to the download service's
/// queue. Exactly one place calls it, once (same reasoning as Dictus's box).
private final class CompletionBox: @unchecked Sendable {
    private let handler: () -> Void
    init(_ handler: @escaping () -> Void) { self.handler = handler }
    func call() { handler() }
}
