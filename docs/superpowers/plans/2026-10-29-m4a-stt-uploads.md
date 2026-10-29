# m4a STT Uploads Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use subagent-driven-development (recommended) or executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `WhisperSTT` uploads recordings as 32 kbps AAC `.m4a` instead of 16-bit WAV, so uploads are ~7.5× smaller, and it falls back to WAV when encoding fails or the server rejects m4a.

**Architecture:** Recording, history, pending-retry storage and every other STT provider keep using WAV `Data`, unchanged. The conversion happens at the last moment, inside `WhisperSTT`, right before the multipart body is built. A new `AudioCaptureService.encodeToM4A(wavData:)` sits next to the existing WAV codec. If it throws, `WhisperSTT` sends the WAV. If the server answers 400 or 415 to the m4a, `WhisperSTT` retries once with the WAV, which keeps third-party OpenAI-compatible servers that only take WAV (e.g. a plain whisper.cpp build) working.

**Tech Stack:** Swift 6, AVFoundation (`AVAudioFile` with `kAudioFormatMPEG4AAC`), Swift Testing, `URLProtocol` mocks. No third-party dependencies.

---

## Background (measured 2026-10-29)

Benchmark against mema (`~/c/mema` on the PC, behind gpu-gate at `:8787`), with clips encoded by Apple's AAC encoder:

- mema already accepts m4a: `/v1/audio/transcriptions` → `/v1/transcribe` saves the upload untyped and runs `ffprobe` + `ffmpeg -ac 1 -ar 16000 -f wav` on it. **No server change is needed.**
- Size at 32 kbps: 15 s goes from 480 KB to 64 KB, 180 s from 5.76 MB to 725 KB.
- Server request time is the same for WAV and m4a (qwen and parakeet). Transcripts are word-for-word identical apart from cosmetic punctuation.
- Upload time saved per 15 s clip: ~0.33 s on 10 Mbps LTE, ~3.3 s on a 1 Mbps uplink. A 3–5 min WAV on a weak uplink overruns `WhisperSTT`'s 30 s `timeoutInterval`; the m4a does not.
- Report: https://files.chiq.me/files/aab779d6-4e5c-4ee9-8cc7-bdfb0962eb75-wav-vs-m4a-mema-benchmark.html

## Scope

- **Changes:** `WhisperSTT` (OpenAI-style `/v1/audio/transcriptions`, which is how Fonos reaches mema, OpenAI, Groq and custom servers).
- **Unchanged:** `ChatSTT` (OpenAI chat `input_audio` accepts only `wav`/`mp3`), `FonosSTT` (desktop fonos server, m4a support unknown), `AppleSTT` (on device, no upload), capture format, stored audio.
- **No conflict with** `docs/superpowers/plans/2026-10-29-retry-failed-transcriptions.md`. That plan stores pending audio as `.wav` and passes it back through the same STT providers, so the m4a conversion applies to retries automatically. Neither plan edits a file the other touches.

## File Structure

| File | Change |
|---|---|
| `FonosApp/Services/AudioCaptureWAVCodec.swift` | Add `encodeToM4A(wavData:)` and `m4aUploadBitRate` to the existing `AudioCaptureService` codec extension. It is already compiled into every target that compiles `WhisperSTT.swift`, so no `project.pbxproj` edit is needed. |
| `FonosApp/Services/WhisperSTT.swift` | Upload m4a, with the WAV fallbacks. Thread an `UploadFile` value through `makeRequest`/`makeBody` instead of raw `audioData`. |
| `FonosAppTests/INV02AudioCaptureTests.swift` | Encoder tests. |
| `FonosAppTests/INV04WhisperSTTTests.swift` | Request-format and fallback tests. |

No new files, so the Xcode project file is not touched.

## Commands

The project's test destination is the iPhone 16 simulator (from `CLAUDE.md`). Single suites:

```bash
xcodebuild test -project FonosApp.xcodeproj -scheme FonosApp \
  -destination 'platform=iOS Simulator,name=iPhone 16' \
  -only-testing:FonosAppTests/INV02AudioCaptureTests
```

```bash
xcodebuild test -project FonosApp.xcodeproj -scheme FonosApp \
  -destination 'platform=iOS Simulator,name=iPhone 16' \
  -only-testing:FonosAppTests/INV04WhisperSTTTests
```

---

### Task 1: AAC encoder

**Files:**
- Modify: `FonosApp/Services/AudioCaptureWAVCodec.swift` (add after `decodeWAV`, inside `extension AudioCaptureService`)
- Test: `FonosAppTests/INV02AudioCaptureTests.swift`

- [ ] **Step 1: Write the failing tests**

Add these to `struct INV02AudioCaptureTests`, after the test `"WAV decoder rejects a data chunk larger than its payload"`. They use the file's existing `makeMockPCMBuffer` helper (a 440 Hz sine, 16 kHz, mono Int16):

```swift
    // --- M4A upload encoding ---

    @Test("M4A encoder produces an MP4 container")
    func m4aEncoderProducesMP4Container() throws {
        let wavData = try AudioCaptureService.encodeToWAV(buffer: makeMockPCMBuffer(frameCount: 32_000))
        let m4aData = try AudioCaptureService.encodeToM4A(wavData: wavData)
        #expect(m4aData.count > 8)
        #expect(String(bytes: m4aData[4..<8], encoding: .ascii) == "ftyp")
    }

    @Test("M4A encoder output is far smaller than the WAV")
    func m4aEncoderCompresses() throws {
        let wavData = try AudioCaptureService.encodeToWAV(buffer: makeMockPCMBuffer(frameCount: 32_000))
        let m4aData = try AudioCaptureService.encodeToM4A(wavData: wavData)
        // 2 s at 16 kHz Int16 is 64 KB; 32 kbps AAC is ~8 KB plus container.
        #expect(m4aData.count * 4 < wavData.count)
    }

    @Test("M4A encode keeps the recording's duration")
    func m4aEncoderKeepsDuration() throws {
        let wavData = try AudioCaptureService.encodeToWAV(buffer: makeMockPCMBuffer(frameCount: 32_000))
        let m4aData = try AudioCaptureService.encodeToM4A(wavData: wavData)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("inv02-\(UUID().uuidString).m4a")
        defer { try? FileManager.default.removeItem(at: url) }
        try m4aData.write(to: url)

        let file = try AVAudioFile(forReading: url)
        let seconds = Double(file.length) / file.fileFormat.sampleRate
        #expect(abs(seconds - 2.0) < 0.1)
        #expect(file.fileFormat.channelCount == 1)
    }

    @Test("M4A encoder rejects a WAV with no samples")
    func m4aEncoderRejectsEmptyWAV() throws {
        // Header only: the samples the header promises are missing.
        let wavData = Data(try AudioCaptureService.encodeToWAV(buffer: makeMockPCMBuffer()).prefix(44))
        #expect(throws: (any Error).self) {
            _ = try AudioCaptureService.encodeToM4A(wavData: wavData)
        }
    }
```

- [ ] **Step 2: Run the tests and confirm they fail**

Run the INV02 command from **Commands**.
Expected: build failure, `type 'AudioCaptureService' has no member 'encodeToM4A'`.

- [ ] **Step 3: Implement the encoder**

In `FonosApp/Services/AudioCaptureWAVCodec.swift`, add inside `extension AudioCaptureService`, directly after the closing brace of `decodeWAV(data:)`:

```swift
    /// AAC bit rate for STT uploads. 32 kbps mono speech transcribed
    /// word-for-word the same as WAV on mema (qwen, parakeet) at ~1/7.5 the size.
    static let m4aUploadBitRate = 32_000

    /// Re-encode capture WAV as AAC in an MP4 (.m4a) container for upload.
    /// Throws for WAV it cannot decode, including one with no samples.
    nonisolated static func encodeToM4A(wavData: Data) throws -> Data {
        let pcm = try decodeWAV(data: wavData)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("fonos-upload-\(UUID().uuidString).m4a")
        defer { try? FileManager.default.removeItem(at: url) }

        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: pcm.format.sampleRate,
            AVNumberOfChannelsKey: Int(pcm.format.channelCount),
            AVEncoderBitRateKey: m4aUploadBitRate,
        ]
        // AVAudioFile finalizes the MP4 container when it is released, so it
        // must go out of scope before the file is read back.
        do {
            let file = try AVAudioFile(
                forWriting: url,
                settings: settings,
                commonFormat: .pcmFormatInt16,
                interleaved: false
            )
            try file.write(from: pcm)
        }
        return try Data(contentsOf: url)
    }
```

`decodeWAV` already throws `WAVError.invalidData` for an empty data chunk, or for one larger than the bytes present, which covers the no-samples test.

- [ ] **Step 4: Run the tests and confirm they pass**

Run the INV02 command again.
Expected: all INV02 tests pass, including the 4 new ones.

If `m4aEncoderKeepsDuration` fails by a small amount (AAC priming frames), check the actual `seconds` value in the failure message. Widen the tolerance only if it is within 0.15 s. A larger gap means the container was read before it was finalized: confirm that `file` is scoped inside the `do { }` block.

- [ ] **Step 5: Commit**

```bash
git add FonosApp/Services/AudioCaptureWAVCodec.swift FonosAppTests/INV02AudioCaptureTests.swift
git commit -m "feat(stt): AAC m4a encoder for uploads"
```

---

### Task 2: WhisperSTT uploads m4a with WAV fallback

**Files:**
- Modify: `FonosApp/Services/WhisperSTT.swift` (`transcribe(audioData:language:prompt:temperature:)` at ~line 56, `makeRequest` at ~line 117, `makeBody` at ~line 141)
- Test: `FonosAppTests/INV04WhisperSTTTests.swift`

Behavior:
1. Try `encodeToM4A`. If it throws, upload the WAV (one request).
2. Upload the m4a as `filename="audio.m4a"`, `Content-Type: audio/mp4`.
3. If the m4a request returns HTTP **400 or 415**, log it and send the same request again with the WAV (`audio.wav`, `audio/wav`). Any other status, including 401, goes to `validate` as before, with no retry.

- [ ] **Step 1: Write the failing tests**

In `FonosAppTests/INV04WhisperSTTTests.swift`:

(a) Add `import AVFoundation` below `import Foundation` at the top.

(b) Add these helpers after `dummyWAVData()`:

```swift
/// 1 s of a 440 Hz tone as capture-format WAV, which the m4a encoder accepts.
private func toneWAVData() throws -> Data {
    let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000,
                               channels: 1, interleaved: false)!
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16_000)!
    buffer.frameLength = 16_000
    for i in 0..<16_000 {
        buffer.int16ChannelData![0][i] = Int16(sin(Double(i) / 16_000 * 440 * 2 * .pi) * 8_000)
    }
    return try AudioCaptureService.encodeToWAV(buffer: buffer)
}

/// The multipart file name of the upload ("audio.m4a" / "audio.wav"), read as
/// bytes because an AAC body is not valid UTF-8.
private func uploadedFilename(_ request: URLRequest) -> String? {
    guard let body = request.httpBody else { return nil }
    for name in ["audio.m4a", "audio.wav"]
    where body.range(of: Data("filename=\"\(name)\"".utf8)) != nil {
        return name
    }
    return nil
}
```

(c) Add these tests to `struct INV04WhisperSTTTests`, after `requestTargetsCorrectURL`:

```swift
    // --- Upload format ---

    @Test("WhisperSTT uploads recordings as m4a")
    func uploadsM4A() async throws {
        var capturedRequest: URLRequest?
        MockURLProtocol.requestHandler = { req in
            capturedRequest = req
            return okResponse(for: kOpenAITranscriptURL, body: #"{"text":"hello"}"#)
        }
        let stt = makeWhisperSTT(session: makeSession())
        let text = try await stt.transcribe(audioData: try toneWAVData(), language: "en")
        #expect(text == "hello")
        let request = try #require(capturedRequest)
        #expect(uploadedFilename(request) == "audio.m4a")
        #expect(request.httpBody?.range(of: Data("Content-Type: audio/mp4".utf8)) != nil)
    }

    @Test("WhisperSTT retries as WAV when the server rejects m4a", arguments: [400, 415])
    func retriesAsWAVWhenM4ARejected(statusCode: Int) async throws {
        var filenames: [String?] = []
        MockURLProtocol.requestHandler = { req in
            let name = uploadedFilename(req)
            filenames.append(name)
            if name == "audio.m4a" {
                return errorResponse(for: kOpenAITranscriptURL, statusCode: statusCode)
            }
            return okResponse(for: kOpenAITranscriptURL, body: #"{"text":"from wav"}"#)
        }
        let stt = makeWhisperSTT(session: makeSession())
        let text = try await stt.transcribe(audioData: try toneWAVData(), language: "en")
        #expect(text == "from wav")
        #expect(filenames == ["audio.m4a", "audio.wav"])
    }

    @Test("WhisperSTT does not retry as WAV on 401")
    func noWAVRetryOnAuthFailure() async throws {
        var requestCount = 0
        MockURLProtocol.requestHandler = { _ in
            requestCount += 1
            return errorResponse(for: kOpenAITranscriptURL, statusCode: 401)
        }
        let stt = makeWhisperSTT(session: makeSession())
        await #expect(throws: STTError.self) {
            _ = try await stt.transcribe(audioData: try toneWAVData(), language: "en")
        }
        #expect(requestCount == 1)
    }

    @Test("WhisperSTT sends WAV when the audio cannot be encoded")
    func sendsWAVWhenEncodingFails() async throws {
        var filenames: [String?] = []
        MockURLProtocol.requestHandler = { req in
            filenames.append(uploadedFilename(req))
            return okResponse(for: kOpenAITranscriptURL, body: #"{"text":"hello"}"#)
        }
        let stt = makeWhisperSTT(session: makeSession())
        // Header-only WAV: no samples, so encodeToM4A throws.
        _ = try await stt.transcribe(audioData: dummyWAVData(), language: "en")
        #expect(filenames == ["audio.wav"])
    }
```

- [ ] **Step 2: Run the tests and confirm they fail**

Run the INV04 command from **Commands**.
Expected: `uploadsM4A` fails (`"audio.wav"` is not `"audio.m4a"`), and both `retriesAsWAVWhenM4ARejected` cases fail (`filenames == ["audio.wav"]`). `noWAVRetryOnAuthFailure` and `sendsWAVWhenEncodingFails` already pass, since today there is no retry and the upload is always WAV. They are regression guards for Step 3. All pre-existing INV04 tests pass.

- [ ] **Step 3: Implement**

In `FonosApp/Services/WhisperSTT.swift`:

(a) Replace the body of `private func transcribe(audioData:language:prompt:temperature:)` with:

```swift
        try Task.checkCancellation()
        try validateRemoteAccess()
        let (urlString, url) = try transcriptionEndpoint()
        let wav = UploadFile.wav(audioData)
        let upload = (try? AudioCaptureService.encodeToM4A(wavData: audioData)).map(UploadFile.m4a) ?? wav
        sttLog.info("🌐 WhisperSTT POST \(urlString), model=\(self.modelID), \(upload.filename)=\(upload.data.count) bytes (wav \(audioData.count))")
        var (data, response) = try await send(
            makeRequest(url: url, file: upload, language: language, prompt: prompt, temperature: temperature),
            urlString: urlString
        )
        if upload.filename != wav.filename,
           let status = (response as? HTTPURLResponse)?.statusCode,
           status == 400 || status == 415 {
            // Servers without an AAC decoder (e.g. whisper.cpp built without
            // ffmpeg) reject m4a; WAV is the format every endpoint accepts.
            sttLog.info("🌐 m4a rejected with HTTP \(status), retrying as WAV")
            try Task.checkCancellation()
            (data, response) = try await send(
                makeRequest(url: url, file: wav, language: language, prompt: prompt, temperature: temperature),
                urlString: urlString
            )
        }
        try Task.checkCancellation()
        try validate(response: response, data: data)
        return try parseTranscript(from: data)
```

(b) Change `makeRequest` to take the upload instead of `audioData`:

```swift
    private func makeRequest(
        url: URL,
        file: UploadFile,
        language: String?,
        prompt: String?,
        temperature: Double?
    ) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        if !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }

        let boundary = UUID().uuidString
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = makeBody(
            boundary: boundary,
            file: file,
            language: language,
            prompt: prompt,
            temperature: temperature
        )
        return request
    }
```

(c) In `makeBody`, rename the `audioData: Data` parameter to `file: UploadFile` and replace the `appendFormFile` call with:

```swift
        appendFormFile(&body, boundary: boundary, name: "file", filename: file.filename,
                       mimeType: file.mimeType, data: file.data)
```

(d) Add the value type under `// MARK: - Private helpers`, next to `WhisperResponse`:

```swift
    private struct UploadFile {
        let data: Data
        let filename: String
        let mimeType: String

        static func wav(_ data: Data) -> UploadFile {
            UploadFile(data: data, filename: "audio.wav", mimeType: "audio/wav")
        }

        static func m4a(_ data: Data) -> UploadFile {
            UploadFile(data: data, filename: "audio.m4a", mimeType: "audio/mp4")
        }
    }
```

- [ ] **Step 4: Run the tests and confirm they pass**

Run the INV04 command again.
Expected: all INV04 tests pass, including both arguments of `retriesAsWAVWhenM4ARejected`.

- [ ] **Step 5: Run the whole suite**

```bash
xcodebuild test -project FonosApp.xcodeproj -scheme FonosApp \
  -destination 'platform=iOS Simulator,name=iPhone 16'
```

Expected: `** TEST SUCCEEDED **`. Pay particular attention to `QD04ErrorTests`, `INV11OfflineTests`, `STTServiceTests` and `VocabTests`. They build `WhisperSTT` with header-only WAV, which takes the "cannot encode → WAV" path, so their assertions should not change. If one of them inspects the body as UTF-8 and now fails, it was given real audio: switch it to the byte-range check used in `uploadedFilename`.

- [ ] **Step 6: Commit**

```bash
git add FonosApp/Services/WhisperSTT.swift FonosAppTests/INV04WhisperSTTTests.swift
git commit -m "feat(stt): upload m4a to Whisper-style endpoints, fall back to WAV"
```

---

### Task 3: Verify against mema

No code. This confirms that the iOS encoder's output (not just the Mac's `afconvert`) transcribes on the real server.

- [ ] **Step 1: Build for the simulator**

```bash
xcodebuild build -project FonosApp.xcodeproj -scheme FonosApp \
  -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 2: Dictate through the mema profile**

Run the app (simulator, or a device via the OTA pipeline) with the STT profile that points at mema/gpu-gate selected. Dictate about 15 s.
Expected: the transcript appears. In the app logs (subsystem used by `sttLog`), the request line shows `audio.m4a=` with roughly 1/7 of the `wav` byte count, and there is **no** `m4a rejected` line.

- [ ] **Step 3: Confirm on the gate**

```bash
curl -s http://192.168.1.3:8787/gpu-gate/status
```

Expected: the last mema request is `POST /v1/audio/transcriptions -> 200 OK`.

If mema answers 415, its log (tmux session `gpu` on the PC) shows `audio_error=`. Check that the uploaded bytes start with `....ftyp`. The fallback will have sent the WAV, so the user still gets a transcript, but the speedup is lost.
