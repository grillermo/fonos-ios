@preconcurrency import AVFoundation
import Combine
import os.log

private let playerLog = Logger(subsystem: "com.fonos.ios", category: "PendingRecordingPlayer")

/// One audio clip being played.
@MainActor
protocol PendingAudioClip: AnyObject {
    var onFinish: (@MainActor () -> Void)? { get set }
    func play() -> Bool
    func stop()
}

@MainActor
private final class AVPendingAudioClip: NSObject, PendingAudioClip, AVAudioPlayerDelegate {
    var onFinish: (@MainActor () -> Void)?
    private let player: AVAudioPlayer

    init(url: URL) throws {
        player = try AVAudioPlayer(contentsOf: url)
        super.init()
        player.delegate = self
    }

    func play() -> Bool { player.play() }
    func stop() { player.stop() }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in self.onFinish?() }
    }

    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        Task { @MainActor in self.onFinish?() }
    }
}

/// Keyboard Ready and capture share `AVAudioSession`, so playback must never
/// deactivate it or change its category while Ready's engine runs.
private enum PendingPlaybackSession {
    @MainActor
    static func begin() throws {
        let session = AVAudioSession.sharedInstance()
        if BackgroundRecordingService.shared.isKeyboardReady {
            // Ready's category has no default-to-speaker; without this the
            // clip plays through the earpiece.
            try session.overrideOutputAudioPort(.speaker)
        } else {
            try session.setCategory(.playback, mode: .default)
            try session.setActive(true, options: .notifyOthersOnDeactivation)
        }
    }

    @MainActor
    static func end() {
        let session = AVAudioSession.sharedInstance()
        if BackgroundRecordingService.shared.isKeyboardReady {
            try? session.overrideOutputAudioPort(.none)
        } else {
            try? session.setActive(false, options: .notifyOthersOnDeactivation)
        }
    }
}

/// Plays one pending recording at a time. There is no pause: a clip plays to
/// its end or stops.
@MainActor
final class PendingRecordingPlayer: ObservableObject {
    static let shared = PendingRecordingPlayer()

    @Published private(set) var playingID: UUID?

    /// True while a recording or transcription runs. Set by `ContentView`.
    var isBlocked: @MainActor () -> Bool = { false }

    private let store: PendingRecordingStore
    private let makeClip: @MainActor (URL) throws -> any PendingAudioClip
    private let beginSession: @MainActor () throws -> Void
    private let endSession: @MainActor () -> Void
    private var clip: (any PendingAudioClip)?
    private var holdsSession = false
    private var observer: AnyCancellable?

    init(
        store: PendingRecordingStore = .shared,
        makeClip: @escaping @MainActor (URL) throws -> any PendingAudioClip = { try AVPendingAudioClip(url: $0) },
        beginSession: @escaping @MainActor () throws -> Void = { try PendingPlaybackSession.begin() },
        endSession: @escaping @MainActor () -> Void = { PendingPlaybackSession.end() }
    ) {
        self.store = store
        self.makeClip = makeClip
        self.beginSession = beginSession
        self.endSession = endSession
        observer = NotificationCenter.default
            .publisher(for: .pendingRecordingsChanged)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                MainActor.assumeIsolated { self?.stopIfRemoved() }
            }
    }

    /// Plays the recording, or stops it if it is already playing.
    func toggle(_ id: UUID) {
        if playingID == id {
            stop()
            return
        }
        stop()
        guard !isBlocked() else { return }
        do {
            let clip = try makeClip(store.audioURL(id))
            try beginSession()
            holdsSession = true
            clip.onFinish = { [weak self, weak clip] in
                guard let self, self.clip === clip else { return }
                self.stop()
            }
            guard clip.play() else {
                playerLog.error("Could not start playback")
                stop()
                return
            }
            self.clip = clip
            playingID = id
        } catch {
            playerLog.error("Could not play recording: \(error.localizedDescription)")
            stop()
        }
    }

    func stop() {
        clip?.stop()
        clip = nil
        playingID = nil
        if holdsSession {
            holdsSession = false
            endSession()
        }
    }

    private func stopIfRemoved() {
        guard let playingID, store.recording(id: playingID) == nil else { return }
        stop()
    }
}
