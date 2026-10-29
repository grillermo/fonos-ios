# Retry failed transcriptions

## Goal

When a recording's transcription run fails, keep the audio on the device so it
can be retried later, and offer Retry from a popup menu on every surface that
shows the failure or the record.

## Decisions

1. **Surfaces: Dictate tab and Notes** save failed audio for retry. The
   keyboard is out of scope (spec review: "Remove the keyboard surfaces,
   nothing in this plan touches the keyboard transcription."). Rationale: keep
   this change to the main app's own recording paths.
2. **Trigger: any transcription failure** saves the recording, not only
   connection errors. Rationale: keeping audio beats losing it to an error
   class we guessed wrong.
3. **Retry UI: Dictate error state, History list, Notebook detail.**
   Rationale: retry where the failure is seen and where the record lives.
4. **Manual retry only**; no automatic retry on reconnect. Rationale: no
   surprise outputs firing later; simplest.
5. **Retry uses the same recipe, compiled from current settings**, not a
   frozen snapshot. Rationale: if a bad key or model caused the failure,
   fixing it in Settings makes Retry work.
6. **A retry from History or a notebook saves the text and copies it**; other
   outputs (Shortcut, Messages) don't fire. Retry from the Dictate error card
   runs the recipe's outputs as usual. Rationale:
   later retries must not trigger surprising side effects.
7. **Keep failed audio until a retry succeeds or the user discards it.**
   Rationale: no silent loss; History shows pending items so they don't pile
   up unseen.
8. **Storage: a file store in the App Group** (`PendingRecordings/<id>.wav` +
   `<id>.json`), no SwiftData schema change. Rationale: no migration risk, and
   the keyboard could use it later without moving files.
9. **"Failure" means the run failed before any text was persisted.** A failed
   output after the recorder hook saved text keeps nothing; empty audio and
   "no speech" results are not kept. Rationale: History already has the text
   in the first case; there is nothing to retry in the second.

## Part 1: saving and retrying

### Components

- **`PendingRecording`** (Codable, `FonosApp/Models/`): `id: UUID`,
  `surface` (`dictate | note`), `workflowID: String?`,
  `notebookID: UUID?`, `createdAt: Date`, `lastError: String`,
  `attempts: Int`, `durationSeconds: TimeInterval`.
- **`PendingRecordingStore`** (`FonosApp/Services/`). Owns `AppGroup/PendingRecordings/`.
  - `save(wav:surface:workflowID:notebookID:error:) throws -> PendingRecording`
  - `all() -> [PendingRecording]` (newest first)
  - `pending(for: .history)` returns `dictate` items;
    `pending(for: .notebook(id))` returns `note` items for that notebook.
  - `audio(id) throws -> Data`, `discard(id)`, `recordAttempt(id, error:)`
  - Writes the WAV first, then the JSON via temp file + atomic rename, so a
    JSON never points at missing audio. `all()` ignores and deletes orphaned
    WAVs older than one hour and JSONs whose WAV is missing.
  - Posts `Notification.Name.pendingRecordingsChanged` after every change so
    open views refresh.
- **`PendingRecordingRetrier`** (`@MainActor`). Re-runs one item:
  1. Loads the audio.
  2. Compiles the recipe from **current** settings: `workflowID` through the
     same factory the Dictate tab uses; `notebookID` through
     `NotebookPipeline.workflowRecipe(for:)`.
  3. Runs `VoiceWorkflowEngine` in one of two modes:
     - **Quiet** (History / notebook): outputs are replaced by
       `ReturnToCallerVoiceWorkflowOutput`. Text is persisted as a
       `DictationSession` (dictate) or a `NoteEntry` (note), then
       copied to `UIPasteboard`.
     - **Full** (Dictate card): the Dictate tab's normal plan with its
       outputs.
  4. Success: `discard(id)`. Failure: `recordAttempt(id, error:)`; the item
     stays.
  - A missing recipe or notebook is reported as the retry error; the item
    stays and can be discarded.
  - Tracks in-flight ids; a second retry of the same id is ignored.

### When audio is saved

In the two processing paths, the non-cancellation `catch` calls
`PendingRecordingStore.save` only if the run's recorder hook had not yet
persisted text:

- `DictationViewModel.finishRecordingWhenIdle` → `surface: .dictate`,
  `workflowID: prepared.persistedDefinition.id`
- `NoteViewModel.recordAndStore` → `surface: .note`, `notebookID: containerId`
  (this path has no recorder hook; any thrown error before `persist` counts)

Not saved: `CancellationError`, empty WAV data, `STTError.noTranscript`. A
store write failure is logged and the original error is shown unchanged.

## Part 2: retry UI and tests

Every surface uses a **popup menu**: a button that opens a menu on tap
(SwiftUI `Menu`), plus a long-press `contextMenu` with the same items on list rows.

| Surface | Shows | Menu items |
|---|---|---|
| Dictate error card | Error text, "Recording saved", a **Retry ▾** button | Retry now (full) · Open in History · Discard recording |
| History list | A "Pending" section above sessions: orange rows with date, duration, recipe name, last error; trailing ⋯ button | Retry (quiet) · Copy error · Discard |
| Notebook detail | Pending rows above that notebook's entries, same style | Retry (quiet) · Copy error · Discard |
| Record note sheet | Error message adds "Saved to this notebook for retry." | none (retry from the notebook) |

`DictationViewModel` gains `lastPendingRecordingID: UUID?`, set when a save
happens and cleared on the next start, so `RecordingState` stays unchanged.
Retry now from the card drives the normal `.processing → .result/.error`
states.

While a retry runs, the row or card shows a spinner and its menu is disabled.
Retry is disabled on the Dictate card while Dictate is busy. A failed retry
leaves the row with its new error and `attempts + 1`.

## Testing (`FonosAppTests`)

- Store: save/list/discard round-trip; notebook and history filtering;
  orphan cleanup; JSON never written without its WAV.
- Saving: both paths saves on an STT failure; saves nothing on
  cancellation, on an output failure after persistence, on empty audio, or on
  `noTranscript`.
- Retrier: quiet mode persists and copies without invoking outputs; full mode
  invokes outputs; success deletes the item; failure increments `attempts`;
  missing recipe/notebook keeps the item.

## Out of scope

The keyboard (its recordings keep today's error-only behavior), automatic
retry, retry limits, retention expiry, retrying with a different recipe,
Live Activity/widget surfaces.
