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
    case verifyUI(snapshotID: String, index: Int, role: String,
                  label: String, target: String)
    /// Independent semantic completion proof, re-checked against the exact
    /// current AX element at execution time. Distinct from recipient proof:
    /// confirming where text would go does not prove the user's whole task.
    case verifyGoal(snapshotID: String, index: Int, role: String,
                    label: String, target: String)
    case typeText(String)
    /// Navigation/query text, never message/document content and never
    /// eligible for Return/Enter commit authority.
    case searchText(String)
    case pasteText(String)
    case key(name: String, mods: [String], repeatCount: Int)
    case pause(ms: Int)
    /// Legacy fallback when the app cannot expose a structured snapshot.
    /// The host requires an authored label and a real AXPress capability.
    case pressElement(label: String)
    /// Exact AXFocus or AXPress capability selected from a structured UI
    /// snapshot. Generic across apps; runtime refuses stale or incomplete
    /// snapshot/app/label/role identity.
    case pressUI(snapshotID: String, index: Int, role: String, label: String)

    /// Steps that put characters or keystrokes into another app.
    var isInput: Bool {
        switch self {
        case .typeText, .searchText, .pasteText, .key: return true
        default: return false
        }
    }

    /// Steps that establish which window the following input lands in.
    var isFocusCheckpoint: Bool {
        switch self {
        case .waitFrontmost, .verifyContext, .verifyUI, .verifyGoal: return true
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
    /// The real Action loop enables this when the engine/app protocol carries
    /// independent structured target evidence. Standalone fixtures and legacy
    /// dry plans keep their historical semantics.
    let requiresUITargetVerification: Bool

    init(goal: String, sends: Bool, steps: [ActionStep], unsupported: String?,
         requiresUITargetVerification: Bool = false) {
        self.goal = goal
        self.sends = sends
        self.steps = steps
        self.unsupported = unsupported
        self.requiresUITargetVerification = requiresUITargetVerification
    }

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
    case contentBeforeTargetVerification(step: Int)
    case weakPressLabel(String)
    case structuredUIRequired(step: Int)
    case incompleteStructuredUI(step: Int)
    case pressRequiresFreshObservation(step: Int)
    case committingPressLabel(String)
    case sendInDraft(step: Int)
    case committingKeyRepeats(step: Int)
    case unsafeKeyChord(String)
    case destructiveKey(String)
    case commitWithoutPendingText(step: Int, key: String)
    case bareSpace
    case unsafeBareKey(String)
    case urlCarriesUnspokenData(token: String)
    case urlEmbedsCredentials

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
        case .contentBeforeTargetVerification(let step):
            return "step \(step) would type message content before the target verifier confirmed the active recipient"
        case .weakPressLabel(let label):
            return "'\(label)' is too short to identify one control to press"
        case .structuredUIRequired(let step):
            return "step \(step) discarded the structured UI; use an exact press_ui index or report done"
        case .incompleteStructuredUI(let step):
            return "step \(step) cannot act on an incomplete structured UI snapshot"
        case .pressRequiresFreshObservation(let step):
            return "step \(step) presses UI; observe the fresh screen before any later step"
        case .committingPressLabel(let label):
            return "'\(label)' names a committing control — pressing is for navigation only"
        case .sendInDraft(let step):
            return "step \(step) would commit typed text, but this is a draft"
        case .committingKeyRepeats(let step):
            return "step \(step) repeats a committing key"
        case .unsafeKeyChord(let chord):
            return "modified chord '\(chord)' is not an allowed Action Mode capability"
        case .destructiveKey(let key):
            return "destructive key '\(key)' is not an Action Mode capability"
        case .commitWithoutPendingText(let step, let key):
            return "step \(step) cannot use \(key) to commit text this action did not create"
        case .urlCarriesUnspokenData(let token):
            return "the URL query carries '\(token)', which the user never said"
        case .urlEmbedsCredentials:
            return "URLs with embedded credentials are not allowed"
        case .bareSpace:
            return "bare Space can activate ambient controls; use type_text to enter spaces"
        case .unsafeBareKey(let key):
            return "bare key '\(key)' is not an allowed Action Mode capability"
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
        static let destructiveKeys: Set<String> = ["delete", "forward_delete"]
        /// The complete unmodified-key surface. Text entry uses bounded
        /// type_text/paste_text; all other bare keys are app command surfaces.
        /// Return/Enter remain only behind their action-owned-text gate.
        // safe_bare_keys: down end enter escape home left page_down page_up return right tab up
        static let safeBareKeys: Set<String> = [
            "escape", "tab", "up", "down", "left", "right",
            "home", "end", "page_up", "page_down", "return", "enter",
        ]
        /// press_element label bounds, mirrored from the engine.
        static let minPressLabelCharacters = 3
        static let maxPressLabelCharacters = 80
        /// Exact structured labels are already bounded at the AX projection.
        /// Do not apply the shorter fuzzy-search bound to their identity.
        static let maxStructuredUILabelCharacters = 180
        /// Words that mark a control as committing or destructive — a press
        /// may navigate, never commit. Checked word-by-word AND against each
        /// adjacent pair joined ("Log Out" → "logout"), so "Ascending" never
        /// trips on the substring "send" but "Send to Priya" is refused.
        /// Mirrored from `velora_engine/actions.py`; the engine test
        /// `test_press_denylist_matches_the_swift_mirror` reads the marker
        /// line below, so keep it in sync with this set.
        // press_denylist: abmelden abschicken absenden accept acheter afmelden agree antworten apagar approve archivar archive archiver beantwoorden bestaetigen bestatigen betalen bevestigen bezahlen block borrar buy call cancel cancella cerrarsesion checkout compartilhar compartir comprar condividi conferma confirm confirmar confirmer deactivate deconnecter delen delete disable discard disconnetti donate doorsturen effacer elimina eliminar eliminare encaminhar enviar envoyer erase excluir forward inoltra invia inviare kaufen kopen leave loeschen logoff logout loschen mute order paga pagar pagare partager pay payer post publicar publier publish purchase reenviar remove renew reply repondre report reset responder rispondi sairdaconta save sedeconnecter send senden share signout submit subscribe subscription supprimer teilen transfer transferer trash tweet uitloggen unfollow unsubscribe verwijderen verzenden weiterleiten withdraw
        static let pressDenyWords: Set<String> = [
            "send", "submit", "post", "publish", "reply", "delete", "remove",
            "discard", "pay", "buy", "purchase", "order", "checkout", "confirm",
            "accept", "agree", "call", "transfer", "forward", "share", "tweet",
            "block", "leave", "archive", "unsubscribe", "logout", "signout",
            "trash", "erase", "reset", "approve", "withdraw", "report", "mute",
            "unfollow", "subscribe",
            // Web-commit verbs (2026-08-21 review): links are pressable in
            // browsers now, and billing/settings pages commit through
            // link-styled controls ("Cancel subscription", "Deactivate
            // account", "Save changes", "Donate", "Renew", "Log off").
            "cancel", "subscription", "deactivate", "disable", "donate",
            "logoff", "save", "renew",
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
        /// A modified key is an app command surface. Keep only Action Mode's
        /// explicit search, reversible compose/tab, copy,
        /// selection and navigation capabilities. Save/close/quit/cut/delete
        /// and unknown chords stay unreachable.
        // safe_modified_key_chords: cmd+a cmd+c cmd+down cmd+end cmd+enter cmd+f cmd+home cmd+k cmd+left cmd+n cmd+page_down cmd+page_up cmd+return cmd+right cmd+t cmd+up option+down option+end option+home option+left option+page_down option+page_up option+right option+up shift+down shift+end shift+home shift+left shift+page_down shift+page_up shift+right shift+tab shift+up
        static let safeModifiedKeyChords: Set<String> = [
            "cmd+a", "cmd+c", "cmd+f", "cmd+k", "cmd+n", "cmd+t",
            "shift+tab", "cmd+return", "cmd+enter",
            "cmd+up", "cmd+down", "cmd+left", "cmd+right",
            "cmd+home", "cmd+end", "cmd+page_up", "cmd+page_down",
            "option+up", "option+down", "option+left", "option+right",
            "option+home", "option+end", "option+page_up", "option+page_down",
            "shift+up", "shift+down", "shift+left", "shift+right",
            "shift+home", "shift+end", "shift+page_up", "shift+page_down",
        ]
        /// Everything after a URL's first `?` or `#` is payload, not address.
        /// Bounds open_url as an outbound channel without trying to judge
        /// which query strings are screen-derived. Defense in depth, NOT a
        /// closed channel: the path is still uncapped below this length, and
        /// a determined plan can chunk across steps.
        static let maxURLQueryCharacters = 256
        /// Content fence for that channel (2026-08-21 bakeoff: a hostile
        /// window title became a validator-accepted open_url carrying a
        /// canary secret to an attacker host). Query/fragment tokens of this
        /// length or longer must come from the spoken command, on-screen
        /// names, or the current page URL. Mirrors the engine's
        /// URL_TOKEN_MIN_CHARS / URL_MACHINERY_TOKENS (contract-tested).
        static let urlTokenMinCharacters = 4
        /// The path is the remaining oversized channel once the query is
        /// fenced and capped. Real paths are short; content stays unfenced
        /// (site-structure vocabulary is unbounded). Mirrors the engine's
        /// MAX_URL_PATH_CHARS.
        static let maxURLPathCharacters = 400
        // url_machinery: search query results watch subject body true false from with about your this that
        static let urlMachineryTokens: Set<String> = [
            "search", "query", "results", "watch", "subject", "body",
            "true", "false",
            "from", "with", "about", "your", "this", "that",
        ]
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
        /// App names observed or targeted in any turn. These are too generic
        /// to satisfy verify_context even after a batch boundary.
        var appNames: Set<String> = []
        /// Singular current input target. Historical/running `appNames` only
        /// filter verify terms and never authorize committing input.
        var currentApp = ""
        /// Allowed sources for open_url query/fragment tokens (the data
        /// fence). Nil disables the fence; the loop runner seeds it from the
        /// transcript, screen names, and page URL, and grows it each turn.
        var urlTokenPool: Set<String>?
        /// Enabled by the real Action loop. Standalone decoder fixtures can
        /// exercise syntax/state rules without manufacturing an engine-only
        /// verifier attestation.
        var requireUITargetVerification = false
        /// Whether the current observation exposed exact indexed AX
        /// capabilities. Label rescans are a degraded fallback only; when
        /// this is true they are refused so a planner cannot discard the
        /// hierarchy after choosing the wrong indexed element.
        var structuredUIAvailable = false
        /// A partial tree can be shown to the model as context, but it cannot
        /// mint an executable indexed capability.
        var structuredUIComplete = false
    }

    /// All tokens found in allowed-source strings (lowercased alphanumeric
    /// runs). Short tokens stay IN the pool — the `urlTokenMinCharacters`
    /// filter applies to URL tokens, not sources: "cat" spoken must
    /// legitimize a "cats" query via the plural variant check.
    static func urlTokenPool(_ sources: [String]) -> Set<String> {
        var pool: Set<String> = []
        for source in sources {
            for run in source.lowercased()
                .split(whereSeparator: { !$0.isLetter && !$0.isNumber }) {
                pool.insert(String(run))
            }
        }
        return pool
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
        var appNames = Array(state.appNames)
        var currentApp = state.currentApp
        /// True once text has been typed that a Return would commit, with no
        /// verify_context since it changed or the screen moved. Seeded from
        /// the previous turns.
        var unverifiedText = state.unverifiedText
        /// True while typed text sits where a committing key could deliver it.
        var pendingText = state.pendingText
        /// Drafts refuse committing keys once text is pending, outright.
        let isDraft = (plan["sends"] as? Bool) == false
        var uiTargetVerified = false

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
                currentApp = app
                steps.append(.openApp(app))
                // Switching apps invalidates any earlier checkpoint: the plan
                // must confirm the app actually came forward before typing —
                // and pending text is unverified again, because its check
                // described a screen this step just left.
                focusEstablished = false
                uiTargetVerified = false
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
                // A user:pass@host authority is itself a data channel.
                guard url.user == nil, url.password == nil else {
                    throw ActionPlanError.urlEmbedsCredentials
                }
                guard url.path.count <= Limits.maxURLPathCharacters else {
                    throw ActionPlanError.badURL(String(raw.prefix(120)))
                }
                // Content fence: query/fragment tokens must come from the
                // session's allowed sources (spoken command, screen names,
                // page URL) — never from titles or the selection.
                if let pool = state.urlTokenPool,
                   let mark = raw.firstIndex(where: { $0 == "?" || $0 == "#" }) {
                    let payload = String(raw[raw.index(after: mark)...])
                        .replacingOccurrences(of: "+", with: " ")
                    let decoded = payload.removingPercentEncoding ?? payload
                    for run in decoded.lowercased()
                        .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
                    where run.count >= Limits.urlTokenMinCharacters
                        && !Limits.urlMachineryTokens.contains(String(run)) {
                        // Plural/singular drift is legitimate ("cat videos"
                        // spoken, "cats" searched); a secret does not become
                        // safe by dropping an "s".
                        let token = String(run)
                        let variants = [token, token + "s",
                                        token.hasSuffix("s") ? String(token.dropLast()) : token]
                        guard variants.contains(where: { pool.contains($0) }) else {
                            throw ActionPlanError.urlCarriesUnspokenData(
                                token: String(token.prefix(40)))
                        }
                    }
                }
                steps.append(.openURL(url))
                // The URL handler is unknown until the runtime observation.
                currentApp = ""
                uiTargetVerified = false
                if pendingText { unverifiedText = true }

            case "wait_frontmost":
                let requested = step["timeout_ms"] as? Int ?? Limits.defaultWaitMs
                let timeout = min(max(requested, 1), Limits.maxWaitMs)
                let app = String(try string("app").prefix(120))
                appNames.append(app)
                currentApp = app
                steps.append(.waitFrontmost(app: app, timeoutMs: timeout))
                focusEstablished = true
                uiTargetVerified = false

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
                // Weak terms are dropped, not fatal: a two-letter word or the
                // app's name/alias must never SATISFY a check, but it must not
                // veto the terms that do identify the target either. ("message
                // Himesh, say Hi" yields ["Himesh", "Hi"].) What remains is
                // strictly stronger than no verification.
                let usable = terms.filter { term in
                    let normalized = AppMatcher.normalize(term)
                    let matchesKnownApp = AppMatcher.bestMatch(
                        for: term, in: appNames) != nil
                    return normalized.count >= Limits.minVerifyTermCharacters
                        && !matchesKnownApp
                }
                guard !usable.isEmpty else {
                    throw ActionPlanError.weakVerifyTerm(terms.joined(separator: ", "))
                }
                steps.append(.verifyContext(anyOf: usable))
                focusEstablished = true
                unverifiedText = false

            case "verify_ui":
                let snapshotID = String(try string("snapshot").prefix(80))
                guard let number = step["index"] as? NSNumber,
                      CFGetTypeID(number) != CFBooleanGetTypeID(),
                      !CFNumberIsFloatType(number), number.intValue >= 0 else {
                    throw ActionPlanError.missingField(step: index, field: "index")
                }
                let role = String(try string("role").prefix(40))
                let label = String(ActionPlan.sanitize(try string("label")).prefix(180))
                let target = String(ActionPlan.sanitize(try string("target")).prefix(80))
                guard AppMatcher.normalize(target).count
                        >= Limits.minVerifyTermCharacters else {
                    throw ActionPlanError.weakVerifyTerm(target)
                }
                if step["purpose"] as? String == "goal" {
                    steps.append(.verifyGoal(
                        snapshotID: snapshotID, index: number.intValue,
                        role: role, label: label, target: target))
                } else {
                    steps.append(.verifyUI(
                        snapshotID: snapshotID, index: number.intValue,
                        role: role, label: label, target: target))
                }
                focusEstablished = true
                uiTargetVerified = true
                unverifiedText = false

            case "type_text", "paste_text", "search_text":
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
                if verb == "search_text" {
                    steps.append(.searchText(cleaned))
                } else {
                    if state.requireUITargetVerification,
                       !isDraft, !uiTargetVerified {
                        throw ActionPlanError.contentBeforeTargetVerification(step: index)
                    }
                    steps.append(verb == "type_text"
                        ? .typeText(cleaned) : .pasteText(cleaned))
                    unverifiedText = true
                    pendingText = true
                }

            case "key":
                guard focusEstablished else {
                    throw ActionPlanError.inputBeforeFocus(step: index)
                }
                let name = try string("key").lowercased()
                guard ActionKey.keyCode(for: name) != nil else {
                    throw ActionPlanError.unknownKey(name)
                }
                guard !Limits.destructiveKeys.contains(name) else {
                    throw ActionPlanError.destructiveKey(name)
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
                if name == "space", mods.isEmpty {
                    throw ActionPlanError.bareSpace
                }
                if mods.isEmpty, !Limits.safeBareKeys.contains(name) {
                    throw ActionPlanError.unsafeBareKey(name)
                }
                if !mods.isEmpty {
                    let chord = (mods.sorted() + [name]).joined(separator: "+")
                    guard Limits.safeModifiedKeyChords.contains(chord) else {
                        throw ActionPlanError.unsafeKeyChord(chord)
                    }
                }
                // `as? Int` would bridge JSON `true` to 1; require a real number.
                let repeatCount = (step["repeat"] as? NSNumber).map {
                    CFNumberIsFloatType($0) || CFGetTypeID($0) == CFBooleanGetTypeID()
                        ? -1 : $0.intValue
                } ?? 1
                guard repeatCount >= 1, repeatCount <= Limits.maxKeyRepeat else {
                    throw ActionPlanError.repeatOutOfRange(repeatCount)
                }
                let committing = Limits.committingKeys.contains(name)
                if committing {
                    guard repeatCount == 1 else {
                        // One validated Return must not become twelve.
                        throw ActionPlanError.committingKeyRepeats(step: index)
                    }
                    guard pendingText else {
                        throw ActionPlanError.commitWithoutPendingText(
                            step: index, key: name)
                    }
                    if isDraft, pendingText {
                        // A draft never commits — navigation goes through
                        // press_element, never a Return that might deliver.
                        throw ActionPlanError.sendInDraft(step: index)
                    }
                    if state.requireUITargetVerification,
                       !isDraft, !uiTargetVerified {
                        throw ActionPlanError.contentBeforeTargetVerification(
                            step: index)
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
                if committing {
                    unverifiedText = false
                    pendingText = false
                } else if !mods.isEmpty, pendingText,
                          !(name == "c" && Set(mods) == Set(["cmd"])) {
                    // Every allowed modified chord except Copy moves focus,
                    // changes selection, or opens a new surface. The prior
                    // verification no longer describes Return's target.
                    unverifiedText = true
                } else if Limits.focusMovingKeys.contains(name), pendingText {
                    // Focus moved, so the check that covered the pending text
                    // no longer describes where a committing key would land.
                    unverifiedText = true
                }
                if !committing, (!mods.isEmpty || Limits.focusMovingKeys.contains(name)) {
                    uiTargetVerified = false
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
                guard !state.structuredUIAvailable else {
                    throw ActionPlanError.structuredUIRequired(step: index)
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
                uiTargetVerified = false
                if pendingText { unverifiedText = true }

            case "press_ui":
                guard focusEstablished else {
                    throw ActionPlanError.inputBeforeFocus(step: index)
                }
                guard !state.structuredUIAvailable || state.structuredUIComplete else {
                    throw ActionPlanError.incompleteStructuredUI(step: index)
                }
                guard index == rawSteps.count - 1 else {
                    throw ActionPlanError.pressRequiresFreshObservation(step: index)
                }
                let snapshotID = String(try string("snapshot").prefix(80))
                guard let number = step["index"] as? NSNumber,
                      CFGetTypeID(number) != CFBooleanGetTypeID(),
                      !CFNumberIsFloatType(number), number.intValue >= 0 else {
                    throw ActionPlanError.missingField(step: index, field: "index")
                }
                let role = String(try string("role").prefix(40))
                let label = String(ActionPlan.sanitize(try string("label"))
                    .prefix(Limits.maxStructuredUILabelCharacters))
                guard AppMatcher.normalize(label).count
                        >= Limits.minPressLabelCharacters else {
                    throw ActionPlanError.weakPressLabel(label)
                }
                guard !ActionPlan.pressLabelIsCommitting(label) else {
                    throw ActionPlanError.committingPressLabel(label)
                }
                steps.append(.pressUI(
                    snapshotID: snapshotID, index: number.intValue,
                    role: role, label: label))
                focusEstablished = false
                uiTargetVerified = false
                if pendingText { unverifiedText = true }

            default:
                throw ActionPlanError.unknownVerb(verb)
            }
        }

        state.stepsUsed += steps.count
        state.totalText = totalText
        state.unverifiedText = unverifiedText
        state.pendingText = pendingText
        state.appNames.formUnion(appNames)
        state.currentApp = currentApp

        let goal = (plan["goal"] as? String).map { String(ActionPlan.sanitize($0).prefix(200)) }
        return ActionPlan(goal: goal ?? "",
                          sends: plan["sends"] as? Bool ?? true,
                          steps: steps,
                          unsupported: nil,
                          requiresUITargetVerification:
                              state.requireUITargetVerification)
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
            case .typeText(let text), .pasteText(let text), .searchText(let text):
                next.totalText += text.count
                if case .searchText = step {
                    break
                }
                next.unverifiedText = true
                next.pendingText = true
            case .verifyContext, .verifyUI, .verifyGoal:
                next.unverifiedText = false
            case .key(let name, let mods, _):
                // The committing and focus-moving branches must mirror
                // `decode` exactly: this function is what actually carries
                // state BETWEEN turns, so a rule that lives only in decode
                // evaporates at the batch boundary and the next turn's
                // Return goes ungated (review finding, 2026-08-04).
                if Limits.committingKeys.contains(name) {
                    next.unverifiedText = false
                    next.pendingText = false
                } else if !mods.isEmpty, next.pendingText,
                          !(name == "c" && Set(mods) == Set(["cmd"])) {
                    next.unverifiedText = true
                } else if Limits.focusMovingKeys.contains(name), next.pendingText {
                    next.unverifiedText = true
                }
            case .openApp(let app):
                next.appNames.insert(app)
                next.currentApp = app
                if next.pendingText { next.unverifiedText = true }
            case .waitFrontmost(let app, _):
                next.appNames.insert(app)
                // Naming a DIFFERENT app moves the screen: the executor asks
                // that app to come forward when the wait would otherwise time
                // out. Same re-arm as open_app — a verification made about the
                // previous app cannot describe where a Return would land.
                if next.pendingText,
                   !AppMatcher.namesSameApp(next.currentApp, app) {
                    next.unverifiedText = true
                }
                next.currentApp = app
            case .openURL:
                next.currentApp = ""
                if next.pendingText { next.unverifiedText = true }
            case .pressElement, .pressUI:
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
