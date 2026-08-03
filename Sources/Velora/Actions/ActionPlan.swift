import Foundation

/// One primitive the executor can perform. The vocabulary is closed by design:
/// there is no shell step, no script step, and no raw-coordinate click, so the
/// worst a bad plan can do is open the wrong app or type into a window the
/// executor has verified.
enum ActionStep: Equatable {
    case openApp(String)
    case openURL(URL)
    case waitFrontmost(app: String, timeoutMs: Int)
    case verifyContext(anyOf: [String])
    case typeText(String)
    case pasteText(String)
    case key(name: String, mods: [String], repeatCount: Int)
    case pause(ms: Int)

    /// Steps that put characters or keystrokes into another app.
    var isInput: Bool {
        switch self {
        case .typeText, .pasteText, .key: return true
        default: return false
        }
    }

    /// Steps that establish which window the following input lands in.
    var isFocusCheckpoint: Bool {
        switch self {
        case .waitFrontmost, .verifyContext: return true
        default: return false
        }
    }
}

struct ActionPlan: Equatable {
    let goal: String
    /// True when carrying the plan out delivers something to another person.
    ///
    /// Absent in the payload means true, which is the safe direction: a caller
    /// that has not opted into sending is refused. Holding the Action hotkey
    /// and speaking the command IS the consent for the voice path; the CLI must
    /// pass `--allow-send` per request. There is no modal confirmation — Esc
    /// aborts a running plan.
    let sends: Bool
    let steps: [ActionStep]
    /// Set when the planner declined; there is nothing to execute.
    let unsupported: String?

    var isExecutable: Bool { unsupported == nil && !steps.isEmpty }
}

enum ActionPlanError: Error, Equatable {
    case notAnObject
    case noSteps
    case tooManySteps(Int)
    case unknownVerb(String)
    case missingField(step: Int, field: String)
    case badURL(String)
    case textTooLong(Int)
    case newlineInText(step: Int)
    case unknownKey(String)
    case unknownModifier(String)
    case repeatOutOfRange(Int)
    case pauseOutOfRange(Int)
    case inputBeforeFocus(step: Int)
    case weakVerifyTerm(String)
    case unverifiedSend(step: Int)

    var message: String {
        switch self {
        case .notAnObject: return "plan is not an object"
        case .noSteps: return "plan has no steps"
        case .tooManySteps(let n): return "plan has \(n) steps"
        case .unknownVerb(let v): return "unknown step '\(v)'"
        case .missingField(let step, let field):
            return "step \(step) is missing '\(field)'"
        case .badURL(let url): return "unsupported link '\(url)'"
        case .textTooLong(let n): return "\(n) characters of text is too much"
        case .newlineInText(let step): return "step \(step) types a newline"
        case .unknownKey(let key): return "unknown key '\(key)'"
        case .unknownModifier(let mod): return "unknown modifier '\(mod)'"
        case .repeatOutOfRange(let n): return "repeat \(n) is out of range"
        case .pauseOutOfRange(let ms): return "pause \(ms) ms is out of range"
        case .inputBeforeFocus(let step):
            return "step \(step) types before the window is verified"
        case .weakVerifyTerm(let term):
            return "'\(term)' doesn't identify anything specific enough to check"
        case .unverifiedSend(let step):
            return "step \(step) would send text the plan never confirmed a target for"
        }
    }
}

extension ActionPlan {
    /// Budgets, mirrored from `velora_engine/actions.py`. The app re-checks
    /// rather than trusting the engine: the engine guards the planner, the app
    /// guards the machine, and only one of them is holding the Accessibility
    /// grant.
    enum Limits {
        static let maxSteps = 24
        static let maxTextChars = 2_000
        static let maxTotalTextChars = 4_000
        static let maxPauseMs = 3_000
        static let maxTotalPauseMs = 12_000
        static let maxWaitMs = 15_000
        static let defaultWaitMs = 8_000
        static let maxKeyRepeat = 12
        static let minVerifyTermCharacters = 3
        /// Deliberately short: every scheme's worst case must be "a window
        /// opened". App deeplinks (`shortcuts://run-shortcut`, raycast,
        /// obsidian, things, vscode) are excluded because they reach scripting
        /// bridges, and a URL step has neither a focus checkpoint nor a
        /// verification step in front of it.
        static let allowedURLSchemes: Set<String> = [
            "https", "http", "slack", "mailto", "tel", "facetime", "sms",
        ]
        /// Keys that commit whatever is currently typed, when unmodified.
        static let committingKeys: Set<String> = ["return", "enter"]
    }

    static func decode(_ object: Any?) throws -> ActionPlan {
        guard let plan = object as? [String: Any] else { throw ActionPlanError.notAnObject }

        if let unsupported = plan["unsupported"] as? String,
           !unsupported.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return ActionPlan(goal: "", sends: false, steps: [],
                              unsupported: String(unsupported.prefix(240)))
        }

        guard let rawSteps = plan["steps"] as? [Any], !rawSteps.isEmpty else {
            throw ActionPlanError.noSteps
        }
        guard rawSteps.count <= Limits.maxSteps else {
            throw ActionPlanError.tooManySteps(rawSteps.count)
        }

        var steps: [ActionStep] = []
        var focusEstablished = false
        var totalText = 0
        var totalPause = 0
        var appNames: [String] = []
        /// True once text has been typed that a bare Return would commit, with
        /// no verify_context since.
        var unverifiedText = false

        for (index, raw) in rawSteps.enumerated() {
            guard let step = raw as? [String: Any],
                  let verb = (step["do"] as? String)?
                      .trimmingCharacters(in: .whitespaces).lowercased()
            else { throw ActionPlanError.missingField(step: index, field: "do") }

            func string(_ field: String) throws -> String {
                guard let value = (step[field] as? String)?
                        .trimmingCharacters(in: .whitespacesAndNewlines),
                      !value.isEmpty
                else { throw ActionPlanError.missingField(step: index, field: field) }
                return value
            }

            switch verb {
            case "open_app":
                let app = String(try string("app").prefix(120))
                appNames.append(app)
                steps.append(.openApp(app))
                // Switching apps invalidates any earlier checkpoint: the plan
                // must confirm the app actually came forward before typing.
                focusEstablished = false

            case "open_url":
                let raw = try string("url")
                guard let url = URL(string: raw), let scheme = url.scheme?.lowercased(),
                      Limits.allowedURLSchemes.contains(scheme),
                      !raw.unicodeScalars.contains(where: {
                          CharacterSet.controlCharacters.contains($0)
                      })
                else { throw ActionPlanError.badURL(String(raw.prefix(120))) }
                steps.append(.openURL(url))

            case "wait_frontmost":
                let requested = step["timeout_ms"] as? Int ?? Limits.defaultWaitMs
                let timeout = min(max(requested, 1), Limits.maxWaitMs)
                let app = String(try string("app").prefix(120))
                appNames.append(app)
                steps.append(.waitFrontmost(app: app, timeoutMs: timeout))
                focusEstablished = true

            case "verify_context":
                let raw = step["expect"] ?? step["any_of"]
                var terms: [String] = []
                if let single = raw as? String { terms = [single] }
                else if let list = raw as? [Any] {
                    terms = list.compactMap { $0 as? String }
                }
                terms = terms
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
                    .prefix(6)
                    .map { String($0.prefix(80)) }
                guard !terms.isEmpty else {
                    throw ActionPlanError.missingField(step: index, field: "expect")
                }
                let appTerms = Set(appNames.map(AppMatcher.normalize))
                for term in terms {
                    let normalized = AppMatcher.normalize(term)
                    guard normalized.count >= Limits.minVerifyTermCharacters else {
                        throw ActionPlanError.weakVerifyTerm(term)
                    }
                    // "Slack" is in every Slack window title: verifying it
                    // proves the app is open, not that the conversation is right.
                    guard !appTerms.contains(normalized) else {
                        throw ActionPlanError.weakVerifyTerm(term)
                    }
                }
                steps.append(.verifyContext(anyOf: terms))
                focusEstablished = true
                unverifiedText = false

            case "type_text", "paste_text":
                guard focusEstablished else {
                    throw ActionPlanError.inputBeforeFocus(step: index)
                }
                guard let text = step["text"] as? String, !text.isEmpty else {
                    throw ActionPlanError.missingField(step: index, field: "text")
                }
                guard !text.contains("\n"), !text.contains("\r") else {
                    throw ActionPlanError.newlineInText(step: index)
                }
                guard text.count <= Limits.maxTextChars else {
                    throw ActionPlanError.textTooLong(text.count)
                }
                let cleaned = ActionPlan.sanitize(text)
                guard !cleaned.trimmingCharacters(in: .whitespaces).isEmpty else {
                    throw ActionPlanError.missingField(step: index, field: "text")
                }
                totalText += cleaned.count
                guard totalText <= Limits.maxTotalTextChars else {
                    throw ActionPlanError.textTooLong(totalText)
                }
                steps.append(verb == "type_text" ? .typeText(cleaned) : .pasteText(cleaned))
                unverifiedText = true

            case "key":
                guard focusEstablished else {
                    throw ActionPlanError.inputBeforeFocus(step: index)
                }
                let name = try string("key").lowercased()
                guard ActionKey.keyCode(for: name) != nil else {
                    throw ActionPlanError.unknownKey(name)
                }
                var mods: [String] = []
                for rawMod in (step["mods"] as? [Any] ?? []) {
                    guard let text = rawMod as? String else {
                        throw ActionPlanError.unknownModifier("\(rawMod)")
                    }
                    let canonical = ActionPlan.canonicalModifier(text)
                    guard ActionModifier(rawValue: canonical) != nil else {
                        throw ActionPlanError.unknownModifier(text)
                    }
                    if !mods.contains(canonical) { mods.append(canonical) }
                }
                // `as? Int` would bridge JSON `true` to 1; require a real number.
                let repeatCount = (step["repeat"] as? NSNumber).map {
                    CFNumberIsFloatType($0) || CFGetTypeID($0) == CFBooleanGetTypeID()
                        ? -1 : $0.intValue
                } ?? 1
                guard repeatCount >= 1, repeatCount <= Limits.maxKeyRepeat else {
                    throw ActionPlanError.repeatOutOfRange(repeatCount)
                }
                let committing = Limits.committingKeys.contains(name) && mods.isEmpty
                if committing, unverifiedText {
                    // The failure this prevents: a swallowed ⌘K meant the
                    // recipient's name went into the conversation already on
                    // screen, and this Return sends it to the wrong person.
                    throw ActionPlanError.unverifiedSend(step: index)
                }
                steps.append(.key(name: name, mods: mods, repeatCount: repeatCount))
                if committing { unverifiedText = false }

            case "pause":
                let ms = step["ms"] as? Int ?? 300
                guard ms > 0, ms <= Limits.maxPauseMs else {
                    throw ActionPlanError.pauseOutOfRange(ms)
                }
                totalPause += ms
                guard totalPause <= Limits.maxTotalPauseMs else {
                    throw ActionPlanError.pauseOutOfRange(totalPause)
                }
                steps.append(.pause(ms: ms))

            default:
                throw ActionPlanError.unknownVerb(verb)
            }
        }

        let goal = (plan["goal"] as? String).map { String(ActionPlan.sanitize($0).prefix(200)) }
        return ActionPlan(goal: goal ?? "",
                          sends: plan["sends"] as? Bool ?? true,
                          steps: steps,
                          unsupported: nil)
    }

    /// Drops control and bidi-override characters. A right-to-left override in
    /// a message would make the confirmation preview read differently from what
    /// actually gets typed.
    static func sanitize(_ text: String) -> String {
        String(String.UnicodeScalarView(text.unicodeScalars.filter { scalar in
            if scalar == "\t" { return true }
            switch scalar.properties.generalCategory {
            case .control, .format, .surrogate, .privateUse, .unassigned:
                return false
            default:
                return true
            }
        }))
    }

    static func canonicalModifier(_ name: String) -> String {
        switch name.trimmingCharacters(in: .whitespaces).lowercased() {
        case "command", "meta": return "cmd"
        case "ctrl": return "control"
        case "alt", "opt": return "option"
        case let other: return other
        }
    }
}
