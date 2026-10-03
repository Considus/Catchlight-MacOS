import AppKit
import XCTest

final class ShortcutTests: XCTestCase {
    private func assert(_ notation: String, _ key: String, _ modifiers: NSEvent.ModifierFlags,
                        file: StaticString = #filePath, line: UInt = #line) {
        guard let s = Shortcut(notation) else { return XCTFail("\(notation) did not parse", file: file, line: line) }
        XCTAssertEqual(s.keyEquivalent, key, notation, file: file, line: line)
        XCTAssertEqual(s.modifiers, modifiers, notation, file: file, line: line)
    }

    func testLettersAreLowerCaseWithExplicitShift() {
        assert("Mod+N", "n", [.command])
        assert("Mod+Shift+N", "n", [.command, .shift])
        assert("Mod+Alt+Shift+V", "v", [.command, .option, .shift])
        assert("Ctrl+Mod+F", "f", [.control, .command])
    }

    func testModifierOrderDoesNotMatter() {
        XCTAssertEqual(Shortcut("Shift+Mod+N"), Shortcut("Mod+Shift+N"))
    }

    func testDigitsAndPunctuation() {
        assert("Mod+1", "1", [.command])
        assert("Mod+Shift+7", "7", [.command, .shift])
        assert("Mod+Alt+0", "0", [.command, .option])
        assert("Mod+,", ",", [.command])
    }

    func testNamedKeys() {
        assert("Mod+Backspace", "\u{8}", [.command])
        assert("Mod+Alt+Backspace", "\u{8}", [.command, .option])
        assert("Mod+Alt+Right", String(Character(UnicodeScalar(NSRightArrowFunctionKey)!)), [.command, .option])
        assert("Ctrl+Mod+Space", " ", [.control, .command])
        assert("Delete", String(Character(UnicodeScalar(NSDeleteFunctionKey)!)), [])
        assert("F11", String(Character(UnicodeScalar(NSF11FunctionKey)!)), [])
    }

    func testUnknownNotationIsRefused() {
        XCTAssertNil(Shortcut(""))
        XCTAssertNil(Shortcut("Mod+"))
        XCTAssertNil(Shortcut("Cmd+N"), "only Mod means ⌘")
        XCTAssertNil(Shortcut("Mod+Mod+N"))
        XCTAssertNil(Shortcut("Mod+PageDown"))
        XCTAssertNil(Shortcut("Mod+é"))
    }
}
