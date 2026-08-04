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
    /// Press the on-screen control whose visible label matches — a chat row in
    /// a search list, a link in results. Label-addressed, never a coordinate,
    /// and never a committing control (the label denylist below).
    case pressElement(label: String)

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
    case weakPressLabel(String)
    case committingPressLabel(String)
    case sendInDraft(step: Int)
    case committingKeyRepeats(step: Int)

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
        case .weakPressLabel(let label):
            return "'\(label)' is too short to identify one control to press"
        case .committingPressLabel(let label):
            return "'\(label)' names a committing control — pressing is for navigation only"
        case .sendInDraft(let step):
            return "step \(step) would commit typed text, but this is a draft"
        case .committingKeyRepeats(let step):
            return "step \(step) repeats a committing key"
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
        /// Keys that commit whatever is currently typed — WITH OR WITHOUT
        /// modifiers. ⌘Return is Send in Gmail, Slack (enter-newline mode),
        /// GitHub, Linear; treating only bare Return as committing was a
        /// reviewed bypass. ⌘K stays a shortcut: its key is k, not return.
        static let committingKeys: Set<String> = ["return", "enter"]
        /// Unmodified keys that put a character into the focused field; a
        /// `key` step with one of these (or ⌘V, which pastes) arms the send
        /// gate exactly like type_text. Mirrored from the engine; the pytest
        /// contract test reads the marker line below.
        // printable_keys: a b c d e f g h i j k l m n o p q r s t u v w x y z 0 1 2 3 4 5 6 7 8 9 space comma period slash minus equal semicolon quote left_bracket right_bracket backslash grave
        static let printableKeys: Set<String> = [
            "a", "b", "c", "d", "e", "f", "g", "h", "i", "j", "k", "l", "m",
            "n", "o", "p", "q", "r", "s", "t", "u", "v", "w", "x", "y", "z",
            "0", "1", "2", "3", "4", "5", "6", "7", "8", "9", "space",
            "comma", "period", "slash", "minus", "equal", "semicolon", "quote",
            "left_bracket", "right_bracket", "backslash", "grave",
        ]
        /// press_element label bounds, mirrored from the engine.
        static let minPressLabelCharacters = 3
        static let maxPressLabelCharacters = 80
        /// Words that mark a control as committing or destructive — a press
        /// may navigate, never commit. Checked word-by-word AND against each
        /// adjacent pair joined ("Log Out" → "logout"), so "Ascending" never
        /// trips on the substring "send" but "Send to Priya" is refused.
        /// Mirrored from `velora_engine/actions.py`; the engine test
        /// `test_press_denylist_matches_the_swift_mirror` reads the marker
        /// line below, so keep it in sync with this set.
        // press_denylist: abmelden abschicken absenden accept acheter afmelden agree antworten apagar approve archivar archive archiver beantwoorden bestaetigen bestatigen betalen bevestigen bezahlen block borrar buy call cancella cerrarsesion checkout compartilhar compartir comprar condividi conferma confirm confirmar confirmer deconnecter delen delete discard disconnetti doorsturen effacer elimina eliminar eliminare encaminhar enviar envoyer erase excluir forward inoltra invia inviare kaufen kopen leave loeschen logout loschen mute order paga pagar pagare partager pay payer post publicar publier publish purchase reenviar remove reply repondre report reset responder rispondi sairdaconta sedeconnecter send senden share signout submit subscribe supprimer teilen transfer transferer trash tweet uitloggen unfollow unsubscribe verwijderen verzenden weiterleiten withdraw
        static let pressDenyWords: Set<String> = [
            "send", "submit", "post", "publish", "reply", "delete", "remove",
            "discard", "pay", "buy", "purchase", "order", "checkout", "confirm",
            "accept", "agree", "call", "transfer", "forward", "share", "tweet",
            "block", "leave", "archive", "unsubscribe", "logout", "signout",
            "trash", "erase", "reset", "approve", "withdraw", "report", "mute",
            "unfollow", "subscribe",
            // Localized labels for the same controls. macOS ships localized,
            // and an English-only list meant this gate did not exist at all on
            // a French or Spanish Mac (audited bypass, 2026-08-04). Diacritics
            // are folded before matching, so "Répondre" arrives as "repondre"
            // and "Löschen" as "loschen".
            "enviar", "eliminar", "borrar", "pagar", "comprar", "confirmar",
            "publicar", "responder", "reenviar", "compartir", "archivar",
            "envoyer", "supprimer", "effacer", "payer", "acheter", "confirmer",
            "publier", "repondre", "transferer", "partager", "archiver",
            "senden", "loschen", "loeschen", "bezahlen", "kaufen",
            "bestatigen", "bestaetigen", "antworten", "weiterleiten", "teilen",
            "abschicken", "absenden",
            "excluir", "apagar", "encaminhar", "compartilhar",
            "invia", "inviare", "elimina", "eliminare", "cancella", "paga",
            "pagare", "conferma", "rispondi", "inoltra", "condividi",
            "verzenden", "verwijderen", "betalen", "kopen", "bevestigen",
            "beantwoorden", "doorsturen", "delen",
            // Sign-out, which the first pass covered only in English.
            // Two-word forms are caught by the joined-pair check, so the pair
            // spelling is what goes here — "cerrar" alone would refuse an
            // ordinary Close.
            "cerrarsesion", "deconnecter", "sedeconnecter", "abmelden",
            "afmelden", "disconnetti", "sairdaconta", "uitloggen",
        ]
        /// The same controls in scripts the word splitter cannot tokenize —
        /// Japanese and Chinese have no spaces, so a word list can never match
        /// them. Checked as substrings of the folded label. Mirrored from
        /// `PRESS_DENY_SUBSTRINGS` in the engine.
        static let pressDenySubstrings: [String] = [
            "送信", "送出", "发送", "發送", "削除", "删除", "刪除",
            "確認", "确认", "支払", "支付", "ログアウト", "退出登录",
            "보내기", "전송", "삭제", "확인", "결제", "로그아웃",
            "отправить", "послать", "удалить", "видалити",
            "оплатить", "подтвердить", "выйти",
            "भेजें", "हटाएं",
            "إرسال", "حذف", "تأكيد", "שלח", "מחק",
            "αποστολή", "διαγραφή", "ส่ง", "ลบ",
        ]
        /// Keys that ACTIVATE the focused control. A bare Space presses the
        /// focused button, so `type_text` → `key tab` → `key space` delivered
        /// a message past every send defense at once (audited bypass,
        /// 2026-08-04). Gated only while text is pending: a Space with
        /// nothing typed is ordinary navigation.
        static let activationKeys: Set<String> = ["space"]
        /// Keys that MOVE FOCUS OR THE SELECTED ROW without committing. Tab
        /// was the other half of the Space bypass; the arrows are the same
        /// hole one key over, aimed at the exact surface the verify gate was
        /// built for — in Slack's ⌘K switcher, type "Priya" → verify → down →
        /// return moved the highlight to Priyanka and sent to her with the
        /// verification still counted good. These do NOT clear the focus
        /// checkpoint (To → Tab → Subject is legitimate); they only re-arm
        /// the send gate.
        static let focusMovingKeys: Set<String> = [
            "tab", "up", "down", "left", "right",
            "home", "end", "page_up", "page_down",
        ]
        /// Everything after a URL's first `?` or `#` is payload, not address.
        /// Bounds open_url as an outbound channel without trying to judge
        /// which query strings are screen-derived. Defense in depth, NOT a
        /// closed channel: the path is still uncapped below this length, and
        /// a determined plan can chunk across steps.
        static let maxURLQueryCharacters = 256
        /// Total URL length, mirroring the engine's `_require_str` bound.
        /// Swift had no equivalent, so a 1,900-character path the engine
        /// refused would have been accepted here (review finding).
        static let maxURLCharacters = 2_000
    }

    /// Budgets and safety state that CARRY ACROSS the turns of one action.
    ///
    /// Focus deliberately does NOT carry: every batch starts unverified,
    /// because between turns the model spends seconds thinking and the user
    /// may have clicked anywhere. `unverifiedText` deliberately DOES: text
    /// typed in turn N must not become committable in turn N+1 just because a
    /// fresh batch started with a clean flag.
    struct BatchState: Equatable {
        var stepsUsed = 0
        var totalText = 0
        /// "Has a check covered the pending text since it changed or the
        /// screen moved" — distinct from `pendingText` on purpose (review
        /// finding): conflating them let type → verify → press-the-wrong-row
        /// → Return deliver text into whatever the press opened.
        var unverifiedText = false
        /// "Is there typed text a committing key would deliver." Cleared
        /// only by the committing key itself.
        var pendingText = false
    }

    /// True when the label names a control that would commit something.
    static func pressLabelIsCommitting(_ label: String) -> Bool {
        // Fold diacritics so localized labels compare as the engine spells
        // them: the engine's word regex is ASCII-only and folds first, so
        // "Répondre" is "repondre" on both sides.
        let folded = label.folding(options: [.diacriticInsensitive, .widthInsensitive],
                                   locale: nil).lowercased()
        let words = folded.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
        let joinedPairs = zip(words, words.dropFirst()).map { $0 + $1 }
        if (words + joinedPairs).contains(where: { Limits.pressDenyWords.contains($0) }) {
            return true
        }
        // Scripts with no word boundaries. The needles are folded the same
        // way, or Arabic "إرسال" would not match its own folded form.
        return Limits.pressDenySubstrings.contains { needle in
            folded.contains(needle.folding(
                options: [.diacriticInsensitive, .widthInsensitive],
                locale: nil).lowercased())
        }
    }

    static func decode(_ object: Any?) throws -> ActionPlan {
        var state = BatchState()
        return try decode(object, state: &state)
    }

    /// Decode one turn's batch as a continuation: budgets and the
    /// unverified-text flag resume from `state`, and `state` is updated only
    /// when the whole batch validates — a rejected batch (and the repair that
    /// follows it) must start from the same pre-batch state.
    static func decode(_ object: Any?, state: inout BatchState) throws -> ActionPlan {
        guard let plan = object as? [String: Any] else { throw ActionPlanError.notAnObject }

        if let unsupported = plan["unsupported"] as? String,
           !unsupported.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return ActionPlan(goal: "", sends: false, steps: [],
                              unsupported: String(unsupported.prefix(240)))
        }

        guard let rawSteps = plan["steps"] as? [Any], !rawSteps.isEmpty else {
            throw ActionPlanError.noSteps
        }
        guard state.stepsUsed + rawSteps.count <= Limits.maxSteps else {
            throw ActionPlanError.tooManySteps(state.stepsUsed + rawSteps.count)
        }

        var steps: [ActionStep] = []
        var focusEstablished = false
        var totalText = state.totalText
        var totalPause = 0  // per batch: pauses bound UI settling, not the action
        var appNames: [String] = []
        /// True once text has been typed that a Return would commit, with no
        /// verify_context since it changed or the screen moved. Seeded from
        /// the previous turns.
        var unverifiedText = state.unverifiedText
        /// True while typed text sits where a committing key could deliver it.
        var pendingText = state.pendingText
        /// Drafts refuse committing keys once text is pending, outright.
        let isDraft = (plan["sends"] as? Bool) == false

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
                // must confirm the app actually came forward before typing —
                // and pending text is unverified again, because its check
                // described a screen this step just left.
                focusEstablished = false
                if pendingText { unverifiedText = true }

            case "open_url":
                let raw = try string("url")
                guard let url = URL(string: raw), let scheme = url.scheme?.lowercased(),
                      Limits.allowedURLSchemes.contains(scheme),
                      !raw.unicodeScalars.contains(where: {
                          CharacterSet.controlCharacters.contains($0)
                      })
                else { throw ActionPlanError.badURL(String(raw.prefix(120))) }
                // Bound open_url as an outbound channel: the planner's prompt
                // holds the selection, window titles and on-screen labels,
                // and a query string can carry any of it off the machine.
                // Spoken searches are short; bulk exfiltration is not.
                guard raw.count <= Limits.maxURLCharacters else {
                    throw ActionPlanError.badURL(String(raw.prefix(120)))
                }
                if let mark = raw.firstIndex(where: { $0 == "?" || $0 == "#" }),
                   raw.distance(from: raw.index(after: mark),
                                to: raw.endIndex) > Limits.maxURLQueryCharacters {
                    throw ActionPlanError.badURL(String(raw.prefix(120)))
                }
                steps.append(.openURL(url))
                if pendingText { unverifiedText = true }

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
                // Weak terms are dropped, not fatal: a two-letter word or the
                // app's own name must never SATISFY a check, but it must not
                // veto the terms that do identify the target either. ("message
                // Himesh, say Hi" yields ["Himesh", "Hi"].) What remains is
                // strictly stronger than no verification.
                let usable = terms.filter { term in
                    let normalized = AppMatcher.normalize(term)
                    return normalized.count >= Limits.minVerifyTermCharacters
                        && !appTerms.contains(normalized)
                }
                guard !usable.isEmpty else {
                    throw ActionPlanError.weakVerifyTerm(terms.joined(separator: ", "))
                }
                steps.append(.verifyContext(anyOf: usable))
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
                pendingText = true

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
                // A bare Space presses the focused control, so once text is
                // pending it can deliver exactly like Return and must clear
                // the same gate. With nothing typed it is plain navigation.
                let activating = mods.isEmpty
                    && Limits.activationKeys.contains(name) && pendingText
                let committing = Limits.committingKeys.contains(name) || activating
                if committing {
                    guard repeatCount == 1 else {
                        // One validated Return must not become twelve.
                        throw ActionPlanError.committingKeyRepeats(step: index)
                    }
                    if isDraft, pendingText {
                        // A draft never commits — navigation goes through
                        // press_element, never a Return that might deliver.
                        throw ActionPlanError.sendInDraft(step: index)
                    }
                    if unverifiedText {
                        // The failure this prevents: a swallowed ⌘K meant the
                        // recipient's name went into the conversation already
                        // on screen, and this Return sends it to the wrong
                        // person.
                        throw ActionPlanError.unverifiedSend(step: index)
                    }
                }
                steps.append(.key(name: name, mods: mods, repeatCount: repeatCount))
                if activating {
                    // Deliberately does NOT clear pendingText the way Return
                    // does: we cannot tell whether the Space pressed a button
                    // or typed a space, and clearing on the typed-a-space
                    // reading would leave the text pending but ungated — the
                    // same hole one step further along.
                    unverifiedText = true
                } else if committing {
                    unverifiedText = false
                    pendingText = false
                } else if (mods.isEmpty && Limits.printableKeys.contains(name))
                            || (name == "v" && mods.contains("cmd")) {
                    // A bare printable key types a character; ⌘V pastes. Text
                    // is now pending exactly as if type_text had run.
                    unverifiedText = true
                    pendingText = true
                } else if Limits.focusMovingKeys.contains(name), pendingText {
                    // Focus moved, so the check that covered the pending text
                    // no longer describes where a committing key would land.
                    unverifiedText = true
                }

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

            case "press_element":
                guard focusEstablished else {
                    throw ActionPlanError.inputBeforeFocus(step: index)
                }
                let label = String(ActionPlan.sanitize(try string("label"))
                    .prefix(Limits.maxPressLabelCharacters))
                guard AppMatcher.normalize(label).count
                        >= Limits.minPressLabelCharacters else {
                    throw ActionPlanError.weakPressLabel(label)
                }
                guard !ActionPlan.pressLabelIsCommitting(label) else {
                    throw ActionPlanError.committingPressLabel(label)
                }
                steps.append(.pressElement(label: label))
                // The press changed what is on screen; whatever follows must
                // re-establish focus before it may type or press again — and
                // pending text is unverified again, because its check
                // described a screen the press just replaced.
                focusEstablished = false
                if pendingText { unverifiedText = true }

            default:
                throw ActionPlanError.unknownVerb(verb)
            }
        }

        state.stepsUsed += steps.count
        state.totalText = totalText
        state.unverifiedText = unverifiedText
        state.pendingText = pendingText

        let goal = (plan["goal"] as? String).map { String(ActionPlan.sanitize($0).prefix(200)) }
        return ActionPlan(goal: goal ?? "",
                          sends: plan["sends"] as? Bool ?? true,
                          steps: steps,
                          unsupported: nil)
    }

    /// The carried state as it stands after only the first `executedCount`
    /// steps of a batch actually ran.
    ///
    /// Decode-time state assumes the whole batch executes; the machine may
    /// stop halfway. The divergence that matters is a verify_context that
    /// FAILED at runtime: decode counted it as clearing the typed text, but
    /// nothing was actually verified — and the next turn's bare Return would
    /// commit text to a target no check ever confirmed. Recomputing from the
    /// executed prefix keeps the safety flag tied to what the machine did,
    /// not what the plan intended. Steps are still budgeted in full (matching
    /// the engine, and the conservative direction).
    static func state(after plan: ActionPlan, executedCount: Int,
                      seed: BatchState) -> BatchState {
        var next = seed
        next.stepsUsed = seed.stepsUsed + plan.steps.count
        for step in plan.steps.prefix(max(0, executedCount)) {
            switch step {
            case .typeText(let text), .pasteText(let text):
                next.totalText += text.count
                next.unverifiedText = true
                next.pendingText = true
            case .verifyContext:
                next.unverifiedText = false
            case .key(let name, let mods, _):
                // The activation and focus-moving branches must mirror
                // `decode` exactly: this function is what actually carries
                // state BETWEEN turns, so a rule that lives only in decode
                // evaporates at the batch boundary and the next turn's
                // Return goes ungated (review finding, 2026-08-04).
                if mods.isEmpty, Limits.activationKeys.contains(name),
                   next.pendingText {
                    next.unverifiedText = true
                } else if Limits.committingKeys.contains(name) {
                    next.unverifiedText = false
                    next.pendingText = false
                } else if (mods.isEmpty && Limits.printableKeys.contains(name))
                            || (name == "v" && mods.contains("cmd")) {
                    next.unverifiedText = true
                    next.pendingText = true
                } else if Limits.focusMovingKeys.contains(name), next.pendingText {
                    next.unverifiedText = true
                }
            case .pressElement, .openApp, .openURL:
                // Navigation that executed moved the screen out from under
                // any pending text; its verification no longer describes
                // where a Return would land.
                if next.pendingText { next.unverifiedText = true }
            default:
                break
            }
        }
        return next
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
