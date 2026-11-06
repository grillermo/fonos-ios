// The Pending row's play button: one clip at a time, no pause, and it never
// keeps playing into a recording.
//
// Run: xcodebuild test -scheme FonosApp -only-testing:FonosAppTests/PendingRecordingPlayerTests

import Testing
import Foundation
@testable import FonosApp

@MainActor
private final class FakeClip: PendingAudioClip {
    var onFinish: (@MainActor () -> Void)?
    var canPlay = true
    var isPlaying = false
    func play() -> Bool { isPlaying = canPlay; return canPlay }
    func stop() { isPlaying = false }
}

private struct NoAudio: Error {}

@MainActor
private final class Harness {
    let store = PendingRecordingStore(
        directory: FileManager.default.temporaryDirectory
            .appendingPathComponent("player-\(UUID().uuidString)", isDirectory: true)
    )
    var clips: [FakeClip] = []
    var nextClipCanPlay = true
    var clipError: (any Error)?
    var sessionsBegun = 0
    var sessionsEnded = 0
    lazy var player = PendingRecordingPlayer(
        store: store,
        makeClip: { [unowned self] _ in
            if let clipError { throw clipError }
            let clip = FakeClip()
            clip.canPlay = nextClipCanPlay
            clips.append(clip)
            return clip
        },
        beginSession: { [unowned self] in sessionsBegun += 1 },
        endSession: { [unowned self] in sessionsEnded += 1 }
    )

    func add() throws -> PendingRecording {
        try store.save(wav: Data(count: 44), surface: .dictate, workflowID: "w", error: "e")
    }

    deinit { try? FileManager.default.removeItem(at: store.directory) }
}

@MainActor
struct PendingRecordingPlayerTests {

    @Test("the button plays, then stops, and releases the audio session")
    func toggleStartsAndStops() throws {
        let h = Harness()
        let recording = try h.add()

        h.player.toggle(recording.id)
        #expect(h.player.playingID == recording.id)
        #expect(h.clips.first?.isPlaying == true)

        h.player.toggle(recording.id)
        #expect(h.player.playingID == nil)
        #expect(h.clips.first?.isPlaying == false)
        #expect(h.sessionsBegun == 1)
        #expect(h.sessionsEnded == 1)
    }

    @Test("playing another recording stops the first")
    func secondReplacesFirst() throws {
        let h = Harness()
        let first = try h.add()
        let second = try h.add()

        h.player.toggle(first.id)
        h.player.toggle(second.id)

        #expect(h.player.playingID == second.id)
        #expect(h.clips[0].isPlaying == false)
        #expect(h.clips[1].isPlaying == true)
    }

    @Test("reaching the end turns the button back to play")
    func finishClears() throws {
        let h = Harness()
        let recording = try h.add()
        h.player.toggle(recording.id)

        h.clips[0].onFinish?()

        #expect(h.player.playingID == nil)
        #expect(h.sessionsEnded == 1)
    }

    @Test("a file that can't be opened or played stays stopped")
    func unplayable() throws {
        let h = Harness()
        let recording = try h.add()

        h.clipError = NoAudio()
        h.player.toggle(recording.id)
        #expect(h.player.playingID == nil)

        h.clipError = nil
        h.nextClipCanPlay = false
        h.player.toggle(recording.id)
        #expect(h.player.playingID == nil)
        #expect(h.sessionsBegun == h.sessionsEnded)
    }

    @Test("nothing plays while a recording or transcription runs")
    func blocked() throws {
        let h = Harness()
        let recording = try h.add()
        h.player.isBlocked = { true }

        h.player.toggle(recording.id)

        #expect(h.player.playingID == nil)
        #expect(h.clips.isEmpty)
        #expect(h.sessionsBegun == 0)
    }

    @Test("removing the recording stops it")
    func removalStops() async throws {
        let h = Harness()
        let recording = try h.add()
        let player = h.player
        player.toggle(recording.id)

        h.store.discard(id: recording.id)

        let start = Date()
        while player.playingID != nil, Date().timeIntervalSince(start) < 5 {
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        #expect(player.playingID == nil)
    }
}
