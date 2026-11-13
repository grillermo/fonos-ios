import DictusModels
import Foundation

/// Speech-to-text on the phone, through the vendored Dictus engines (WhisperKit,
/// Parakeet, Nemotron). The profile's `modelID` is a Dictus catalogue identifier.
///
/// Vocabulary and prompt hints are not passed on: Parakeet takes none, and
/// WhisperKit's `promptTokens` is reported to return empty text (Argmax #372).
struct OnDeviceSTT: STTProvider {
    static let provider = "ondevice"

    let modelID: String
    var watch: TerminationWatch = .shared
    var runLog: OnDeviceRunLog = .shared

    func transcribe(audioData: Data, language: String?) async throws -> String {
        let samples = try OnDeviceAudio.samples(fromWAV: audioData)
        let code = STTLanguageCode.normalized(language)
        let modelID = modelID
        watch.resetPeak()
        let loadMilliseconds = try await watch.during(.loading, modelID: modelID) {
            try await OnDeviceModels.shared.load(modelID)
        }
        let result = try await watch.during(.transcribing, modelID: modelID) {
            try await OnDeviceModels.shared.transcribe(samples: samples, modelID: modelID, language: code)
        }
        runLog.append(OnDeviceRun(
            modelID: modelID,
            finishedAt: Date(),
            audioSeconds: result.audioSeconds,
            loadMilliseconds: loadMilliseconds,
            transcribeMilliseconds: result.transcribeMilliseconds,
            peakFootprintMB: watch.currentBreadcrumb.peakFootprintMB,
            characters: result.text.count
        ))
        let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw STTError.noTranscript }
        return text
    }
}

extension ModelProfile {
    /// The profile that selects one on-device model as an STT engine.
    static func onDevice(modelID: String, displayName: String) -> ModelProfile {
        ModelProfile(
            id: "\(OnDeviceSTT.provider)-\(modelID)",
            name: "On-device · \(displayName)",
            provider: OnDeviceSTT.provider,
            modelID: modelID,
            capabilities: ["stt"]
        )
    }
}
