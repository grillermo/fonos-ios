import Testing
@testable import FonosApp

struct KeyboardCursorNavigatorTests {
    typealias Nav = KeyboardCursorNavigator

    @Test("Character steps move by graphemes in UTF-16 units")
    func characterSteps() {
        #expect(Nav.characterOffset(.left, count: 1, before: "abc", after: "") == -1)
        #expect(Nav.characterOffset(.left, count: 2, before: "abc", after: "") == -2)
        #expect(Nav.characterOffset(.right, count: 5, before: "", after: "xy") == 2)
        #expect(Nav.characterOffset(.left, count: 1, before: "hi👍", after: "") == -2)
        #expect(Nav.characterOffset(.left, count: 1, before: "", after: "x") == nil)
        #expect(Nav.characterOffset(.right, count: 1, before: "x", after: "") == nil)
    }

    @Test("Word steps skip adjacent whitespace then the word")
    func wordSteps() {
        #expect(Nav.wordOffset(.left, before: "hello world  ", after: "") == -7)
        #expect(Nav.wordOffset(.left, before: "hello wor", after: "") == -3)
        #expect(Nav.wordOffset(.right, before: "", after: "  foo bar") == 5)
        #expect(Nav.wordOffset(.right, before: "", after: "") == nil)
    }

    @Test("Up keeps the column on the previous hard line")
    func lineUp() {
        // "abcdef\nxy|z" → column 2 → "ab|cdef"
        #expect(Nav.lineOffset(.up, before: "abcdef\nxy", after: "z") == -7)
        // Column clamps to a shorter previous line: "ab\nwxyz|" → "ab|"
        #expect(Nav.lineOffset(.up, before: "ab\nwxyz", after: "") == -5)
        // Three lines, from the last: "one\ntwo\nth|ree" → "one\ntw|o"
        #expect(Nav.lineOffset(.up, before: "one\ntwo\nth", after: "ree") == -4)
        // First line goes to the start of context.
        #expect(Nav.lineOffset(.up, before: "hello", after: "") == -5)
        #expect(Nav.lineOffset(.up, before: "", after: "x") == nil)
    }

    @Test("Down keeps the column on the next hard line")
    func lineDown() {
        // "ab|c\nwxyz" → column 2 → "wx|yz"
        #expect(Nav.lineOffset(.down, before: "ab", after: "c\nwxyz") == 4)
        // Clamped: "abcd|\nxy\nmore" → "xy|"
        #expect(Nav.lineOffset(.down, before: "abcd", after: "\nxy\nmore") == 3)
        // Column counted from the last line break before the cursor.
        #expect(Nav.lineOffset(.down, before: "zz\nq", after: "\nabc") == 2)
        // Last line goes to the end of context.
        #expect(Nav.lineOffset(.down, before: "a", after: "bcd") == 3)
        #expect(Nav.lineOffset(.down, before: "a", after: "") == nil)
    }

    @Test("CRLF counts as one break of two UTF-16 units")
    func crlf() {
        // "ab\r\ncd|" → "ab|": skip "cd" (2) + "\r\n" (2)
        #expect(Nav.lineOffset(.up, before: "ab\r\ncd", after: "") == -4)
    }
}
