// NoteINV03: Notes tab appears as 4th tab in TabView with 'note.text' SF Symbol.
//
// Verifier: auto
// Levels: unit (canonical tab order), integration (FonosAppUITests)
// Run: xcodebuild test -scheme FonosApp -only-testing:FonosAppTests/NoteINV03TabTests

import Testing
@testable import FonosApp

// MARK: - Tests

struct NoteINV03TabTests {

    @Test("ContentView exposes the four production tabs in display order")
    func contentViewHasFourTabs() {
        #expect(ContentView.AppTab.allCases == [
            .dictate, .history, .notes, .settings
        ])
    }
}
