import Foundation

/// Stand-in for Dictus's `DictationCoordinator`, keeping only the members the
/// vendored `ModelManager` calls. The Neural Engine gate is the important part:
/// two Core ML compiles at once fail with the "E5 bundle" error.
@MainActor
final class DictationCoordinator {
    static let shared = DictationCoordinator()

    private(set) var neuralEngineHolder: String?
    var modelLoadEpoch = 0
    /// Set by the Fonos facade; called after a prewarm so the active model is resident.
    var onPreloadActiveModel: (() -> Void)?

    func acquireNeuralEngine(for holder: String) async throws {
        while neuralEngineHolder != nil {
            try await Task.sleep(nanoseconds: 500_000_000)
        }
        try Task.checkCancellation()
        neuralEngineHolder = holder
    }

    func releaseNeuralEngine(from holder: String) {
        if neuralEngineHolder == holder { neuralEngineHolder = nil }
    }

    func loadWasAbandoned(since epoch: Int) -> Bool {
        epoch != modelLoadEpoch
    }

    func preloadActiveModel() {
        onPreloadActiveModel?()
    }
}
