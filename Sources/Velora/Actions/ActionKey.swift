import ApplicationServices
import Foundation

/// The key vocabulary an action plan may use, and its mapping to virtual key
/// codes.
///
/// Character keys resolve through `Hotkey.keyCode(for:)` so a synthesized ⌘K is
/// the K the user's layout actually produces (positional ANSI codes land on the
/// wrong key on AZERTY/QWERTZ). Named keys are positional by definition and use
/// fixed codes.
///
/// The name list below is one half of a cross-language contract: the engine's
/// `actions.KEY_NAMES` is the other, and `test_key_names_match_the_swift_mirror`
/// fails if they drift. A name the planner may emit but the executor cannot map
/// is a plan that dies halfway through, which for a send-a-message plan means a
/// half-typed message in someone's chat.
///
// keys: return enter tab escape space delete forward_delete up down left right home end page_up page_down a b c d e f g h i j k l m n o p q r s t u v w x y z 0 1 2 3 4 5 6 7 8 9 comma period slash minus equal semicolon quote left_bracket right_bracket backslash grave f1 f2 f3 f4 f5 f6 f7 f8 f9 f10 f11 f12
enum ActionKey {
    /// Named keys whose position is fixed regardless of layout.
    static let namedKeyCodes: [String: CGKeyCode] = [
        "return": 36, "enter": 36, "tab": 48, "space": 49, "delete": 51,
        "escape": 53, "forward_delete": 117,
        "home": 115, "end": 119, "page_up": 116, "page_down": 121,
        "left": 123, "right": 124, "down": 125, "up": 126,
        "f1": 122, "f2": 120, "f3": 99, "f4": 118, "f5": 96, "f6": 97,
        "f7": 98, "f8": 100, "f9": 101, "f10": 109, "f11": 103, "f12": 111,
    ]

    /// Punctuation the planner names in words, with the character each maps to.
    static let punctuation: [String: Character] = [
        "comma": ",", "period": ".", "slash": "/", "minus": "-", "equal": "=",
        "semicolon": ";", "quote": "'", "left_bracket": "[",
        "right_bracket": "]", "backslash": "\\", "grave": "`",
    ]

    /// ANSI fallback for character keys, used when the layout lookup fails
    /// (`Hotkey.keyCode(for:)` returns nil for exotic layouts and for the
    /// punctuation keys some layouts move).
    static let ansiFallback: [Character: CGKeyCode] = [
        "a": 0, "b": 11, "c": 8, "d": 2, "e": 14, "f": 3, "g": 5, "h": 4,
        "i": 34, "j": 38, "k": 40, "l": 37, "m": 46, "n": 45, "o": 31, "p": 35,
        "q": 12, "r": 15, "s": 1, "t": 17, "u": 32, "v": 9, "w": 13, "x": 7,
        "y": 16, "z": 6,
        "0": 29, "1": 18, "2": 19, "3": 20, "4": 21, "5": 23, "6": 22,
        "7": 26, "8": 28, "9": 25,
        ",": 43, ".": 47, "/": 44, "-": 27, "=": 24, ";": 41, "'": 39,
        "[": 33, "]": 30, "\\": 42, "`": 50,
    ]

    /// Every name a plan may use. Order is irrelevant; membership is the contract.
    static var allNames: Set<String> {
        Set(namedKeyCodes.keys)
            .union(punctuation.keys)
            .union(ansiFallback.keys.map(String.init))
    }

    /// The virtual key code for a plan's key name, or nil if it is not in the
    /// vocabulary.
    static func keyCode(for name: String) -> CGKeyCode? {
        let key = name.lowercased()
        if let named = namedKeyCodes[key] { return named }
        let character: Character
        if let punctuationCharacter = punctuation[key] {
            character = punctuationCharacter
        } else if key.count == 1, let only = key.first {
            character = only
        } else {
            return nil
        }
        if let layoutCode = Hotkey.keyCode(for: character) { return layoutCode }
        return ansiFallback[character]
    }
}

/// Modifier names a plan may use.
enum ActionModifier: String, CaseIterable {
    case cmd, shift, option, control, fn

    var flag: CGEventFlags {
        switch self {
        case .cmd: return .maskCommand
        case .shift: return .maskShift
        case .option: return .maskAlternate
        case .control: return .maskControl
        case .fn: return .maskSecondaryFn
        }
    }

    static func flags(for names: [String]) -> CGEventFlags {
        names.reduce(into: CGEventFlags()) { result, name in
            if let modifier = ActionModifier(rawValue: name.lowercased()) {
                result.insert(modifier.flag)
            }
        }
    }
}
