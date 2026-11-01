import Foundation

/// Turns trackpad steps into offsets for
/// `UITextDocumentProxy.adjustTextPosition(byCharacterOffset:)`.
///
/// Keyboard extensions cannot send arrow keys and cannot see the host's
/// layout, so everything is computed from the text the proxy exposes around
/// the cursor (`documentContextBeforeInput` / `AfterInput`). Offsets are in
/// UTF-16 units — what UIKit text inputs use for positions — and always land
/// on a grapheme boundary so an emoji is never split.
///
/// Vertical moves follow hard line breaks only: the keyboard can't know where
/// the host soft-wraps, so "up" inside one long paragraph goes to its start.
enum KeyboardCursorNavigator {

    enum Direction: Sendable {
        case left, right, up, down
    }

    /// Offset for `count` single-character steps left or right, or nil when
    /// the visible context has nothing in that direction.
    static func characterOffset(_ direction: Direction, count: Int, before: String, after: String) -> Int? {
        guard count > 0 else { return nil }
        switch direction {
        case .left:
            let moved = before.suffix(count).utf16.count
            return moved > 0 ? -moved : nil
        case .right:
            let moved = after.prefix(count).utf16.count
            return moved > 0 ? moved : nil
        case .up, .down:
            return nil
        }
    }

    /// Offset for one word step: skip whitespace next to the cursor, then the
    /// word itself — what Option+Arrow does on a Mac.
    static func wordOffset(_ direction: Direction, before: String, after: String) -> Int? {
        switch direction {
        case .left:
            let chars = Array(before)
            var i = chars.count
            while i > 0, chars[i - 1].isWhitespace { i -= 1 }
            while i > 0, !chars[i - 1].isWhitespace { i -= 1 }
            let moved = utf16Count(chars[i...])
            return moved > 0 ? -moved : nil
        case .right:
            let chars = Array(after)
            var i = 0
            while i < chars.count, chars[i].isWhitespace { i += 1 }
            while i < chars.count, !chars[i].isWhitespace { i += 1 }
            let moved = utf16Count(chars[..<i])
            return moved > 0 ? moved : nil
        case .up, .down:
            return nil
        }
    }

    /// Offset for one hard-line step up or down, keeping the cursor's column
    /// (clamped to the target line's length). With no line break in that
    /// direction it goes to the start/end of the visible context instead.
    static func lineOffset(_ direction: Direction, before: String, after: String) -> Int? {
        let beforeChars = Array(before)
        let lineStart = beforeChars.lastIndex(where: \.isNewline).map { $0 + 1 } ?? 0
        let column = beforeChars.count - lineStart

        switch direction {
        case .up:
            guard lineStart > 0 else {
                let moved = utf16Count(beforeChars[...])
                return moved > 0 ? -moved : nil
            }
            let breakIndex = lineStart - 1
            let previousStart = beforeChars[..<breakIndex].lastIndex(where: \.isNewline).map { $0 + 1 } ?? 0
            let previousLength = breakIndex - previousStart
            let target = previousStart + min(column, previousLength)
            return -utf16Count(beforeChars[target...])

        case .down:
            let afterChars = Array(after)
            guard let breakIndex = afterChars.firstIndex(where: \.isNewline) else {
                let moved = utf16Count(afterChars[...])
                return moved > 0 ? moved : nil
            }
            let nextStart = breakIndex + 1
            let nextEnd = afterChars[nextStart...].firstIndex(where: \.isNewline) ?? afterChars.count
            let target = nextStart + min(column, nextEnd - nextStart)
            return utf16Count(afterChars[..<target])

        case .left, .right:
            return nil
        }
    }

    private static func utf16Count(_ chars: ArraySlice<Character>) -> Int {
        chars.reduce(0) { $0 + $1.utf16.count }
    }
}
