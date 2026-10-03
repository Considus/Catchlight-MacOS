import AppKit

/// A menu shortcut in `ui/menu.js`'s portable notation, as AppKit wants it.
///
/// The notation is `+`-separated modifiers, then one key: `Mod` is ⌘, `Ctrl` is ⌃, `Alt` is ⌥,
/// `Shift` is ⇧. The key is a letter, a digit, punctuation such as `,`, or a name (`Backspace`,
/// `Delete`, `Space`, `Left`, `Right`, `Up`, `Down`, `F1`–`F12`). `Mod+Shift+N` is ⇧⌘N.
struct Shortcut: Equatable {
    let keyEquivalent: String
    let modifiers: NSEvent.ModifierFlags

    private static let modifierNames: [String: NSEvent.ModifierFlags] = [
        "Mod": .command, "Ctrl": .control, "Alt": .option, "Shift": .shift,
    ]

    private static func character(_ code: Int) -> String { String(Character(UnicodeScalar(code)!)) }

    private static let namedKeys: [String: String] = {
        var keys: [String: String] = [
            // AppKit shows U+0008 as ⌫ and matches it to the delete key (Finder's ⌘⌫).
            "Backspace": character(NSBackspaceCharacter),
            "Delete": character(NSDeleteFunctionKey),
            "Space": " ",
            "Left": character(NSLeftArrowFunctionKey),
            "Right": character(NSRightArrowFunctionKey),
            "Up": character(NSUpArrowFunctionKey),
            "Down": character(NSDownArrowFunctionKey),
            "Escape": character(0x1B),
            "Tab": character(NSTabCharacter),
            "Enter": character(NSCarriageReturnCharacter),
        ]
        for n in 1...12 { keys["F\(n)"] = character(NSF1FunctionKey + n - 1) }
        return keys
    }()

    /// Parses `notation`, or returns nil if any part of it is not understood, so an
    /// unknown key is never bound to the wrong one.
    init?(_ notation: String) {
        // Split on `+` but keep a trailing `+` as the key, should one ever be used.
        var parts = notation.split(separator: "+", omittingEmptySubsequences: false).map(String.init)
        if notation.hasSuffix("++") { parts.removeLast(2); parts.append("+") }
        guard let key = parts.popLast(), !key.isEmpty else { return nil }

        var modifiers: NSEvent.ModifierFlags = []
        for name in parts {
            guard let flag = Self.modifierNames[name], !modifiers.contains(flag) else { return nil }
            modifiers.insert(flag)
        }

        let equivalent: String
        if let named = Self.namedKeys[key] {
            equivalent = named
        } else if key.count == 1, let scalar = key.unicodeScalars.first, scalar.isASCII, !scalar.properties.isWhitespace {
            // Letters are lower case: AppKit reads an upper-case key equivalent as Shift+key,
            // and Shift is already explicit in the notation.
            equivalent = key.lowercased()
        } else {
            return nil
        }
        self.keyEquivalent = equivalent
        self.modifiers = modifiers
    }
}
