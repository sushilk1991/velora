import Foundation

enum ActionPresentationScope: Equatable {
    case window
    case app
}

enum ActionMediaState: String, Equatable {
    case play
    case pause
}

enum ActionMediaCapability: Equatable {
    case cua(snapshotID: String, index: Int, role: String, label: String)
    case appNative(snapshotID: String, id: String)
}

struct ActionMediaControl: Equatable {
    let state: ActionMediaState
    let capability: ActionMediaCapability

    init(state: ActionMediaState, capability: ActionMediaCapability) {
        self.state = state
        self.capability = capability
    }

    init(state: ActionMediaState, snapshotID: String, index: Int,
         role: String, label: String) {
        self.init(
            state: state,
            capability: .cua(
                snapshotID: snapshotID, index: index,
                role: role, label: label))
    }
}

enum ActionTextOperation: Equatable {
    case type
    case paste
    case search
}

struct ActionTextTarget: Equatable {
    let snapshotID: String
    let index: Int
    let role: String
    let label: String
}

enum ActionStateAssertion: String, Equatable {
    case writtenText = "written_text"
    case selected
}

struct ActionStateCheck: Equatable {
    let snapshotID: String
    let index: Int
    let role: String
    let label: String
    let assertion: ActionStateAssertion
    let expectedValue: String?
}

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
    /// Engine-attested transition from exact routed-window evidence to the
    /// requested app or window in front. The controller never authors it.
    case presentUI(snapshotID: String, bundleID: String, windowID: Int,
                   scope: ActionPresentationScope)
    case typeText(String)
    /// Exact Cua text capability from the current routed-window snapshot.
    /// Partialness is retained; the runtime re-reads this same element before
    /// and after the driver write instead of manufacturing uniqueness.
    case typeTextAt(text: String, operation: ActionTextOperation,
                    target: ActionTextTarget)
    /// Navigation/query text, never message/document content and never
    /// eligible for Return/Enter commit authority.
    case searchText(String)
    case pasteText(String)
    case key(name: String, mods: [String], repeatCount: Int)
    case pause(ms: Int)
    /// Legacy fallback when the app cannot expose a structured snapshot.
    /// The host requires an authored label and a real AXPress capability.
    case pressElement(label: String)
    /// Exact native AX or Cua driver capability selected from a structured UI
    /// snapshot. Runtime refuses stale snapshot/app/window/label/role identity.
    case pressUI(snapshotID: String, index: Int, role: String, label: String)
    /// Idempotent media command bound to one exact Cua click capability. The
    /// runtime re-reads this element and proves the target PID's audio state.
    case mediaControl(ActionMediaControl)
    /// Closed positive postcondition. Swift, not the planner, supplies the
    /// exact PID/window predicates and expected action-owned value.
    case verifyState(ActionStateCheck)

    /// Steps that put characters or keystrokes into another app.
    var isInput: Bool {
        switch self {
        case .typeText, .typeTextAt, .searchText, .pasteText, .key: return true
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

/// A local receipt proves only its own narrow domain. Natural-language text
/// effects need whole-goal proof; media accepts a closed basic-command shape.
enum ActionLocalProof: Equatable {
    case media(state: ActionMediaState, appName: String)
    case state

    func covers(_ command: String) -> Bool {
        guard case .media(let state, let appName) = self else { return false }
        let words = command.lowercased().split {
            !$0.isLetter && !$0.isNumber
        }.map(String.init)
        guard let verb = words.first,
              state.verbs.contains(verb) else { return false }

        let appWords = Set(appName.lowercased().split {
            !$0.isLetter && !$0.isNumber
        }.map(String.init))
        let allowed = appWords.union(Self.mediaWords)
        let remainder = Array(words.dropFirst())
        return !remainder.isEmpty
            && remainder.allSatisfy { allowed.contains($0) }
            && remainder.contains { Self.mediaNouns.contains($0) }
    }

    private static let mediaWords: Set<String> = [
        "app", "audio", "in", "music", "on", "playback", "song", "the",
    ]
    private static let mediaNouns: Set<String> = [
        "audio", "music", "playback", "song",
    ]
}

private extension ActionMediaState {
    var verbs: Set<String> {
        switch self {
        case .play: return ["play", "resume", "start"]
        case .pause: return ["pause", "stop"]
        }
    }
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
    case partialUIUnmentioned(step: Int)
    case invalidStructuredUICapability(step: Int)
    case invalidUIPresentation(step: Int)
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
        case .partialUIUnmentioned(let step):
            return "step \(step) cites a partial UI label absent from the command"
        case .invalidStructuredUICapability(let step):
            return "step \(step) does not cite an exact current UI capability"
        case .invalidUIPresentation(let step):
            return "step \(step) does not cite the exact routed UI window"
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
        // A changed exact result may be one character; the engine attests its
        // complete before/after tree and the app rechecks the live label.
        static let minChangedVerifyCharacters = 1
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
        /// Exact content authored by this action. It is postcondition input,
        /// never screen context or a durable trace value.
        var pendingValue = ""
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
        /// Whole-tree completeness remains necessary for absence, uniqueness,
        /// and completion. A partial tree carries only exact affirmative
        /// capabilities.
        var structuredUIComplete = false
        /// The immutable spoken command. Sharing one non-generic mentioned term
        /// is only a lexical bound; the independent reviewer proves semantics.
        var spokenCommand = ""
        /// The exact current structured evidence. The engine and app both
        /// validate the selected source-specific capability; runtime still
        /// owns native AX references and Cua token lineage.
        var structuredUISnapshot: ActionUISnapshot?
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

    private static let commandMentionWords: Set<String> = [
        "app", "bring", "chat", "click", "composer", "conversation",
        "display", "find", "focus", "go", "launch", "me", "message",
        "messages", "navigate", "open", "please", "press", "search", "show",
        "switch", "take", "the", "to", "up", "with",
    ]

    // recipient_intent: comment dm email mail message post reply text | draft prepare write + chat channel comment conversation discord dm email gmail imessage mail messenger post recipient reply signal slack teams telegram thread whatsapp
    private static let contentWords: Set<String> = [
        "comment", "dm", "email", "mail", "message", "post", "reply", "text",
    ]
    private static let contextWords: Set<String> = [
        "chat", "channel", "comment", "conversation", "discord", "dm",
        "email", "gmail", "imessage", "mail", "messenger", "post",
        "recipient", "reply", "signal", "slack", "teams", "telegram",
        "thread", "whatsapp",
    ]
    private static let composeWords: Set<String> = ["draft", "prepare", "write"]
    private static let presentationIntentPrefixes: [[String]] = [
        ["open"], ["show"], ["display"], ["launch"],
        ["navigate", "to"], ["go", "to"], ["switch", "to"],
        ["switch", "me", "to"], ["take", "me", "to"], ["bring", "up"],
    ]
    private static let appOnlyIgnoredWords: Set<String> = [
        "app", "application", "please", "the",
    ]
    private static let browserModalityWords: Set<String> = [
        "browser", "online", "tab", "url", "web", "webpage", "website",
    ]
    private static let browserAddressPattern =
        #"(?:https?://|www\.|\b[a-z0-9-]+\.[a-z]{2,24}(?:\b|[/#?])|\bdot\s+[a-z]{2,24}\b)"#

    static func isRecipientContent(
        _ command: String, bundleID: String?
    ) -> Bool {
        guard let category = ModeCategory.category(forBundleID: bundleID)
        else { return false }
        guard category == .chat || category == .email else { return false }
        let words = Set(AppMatcher.words(command))
        let hasIntent = !words.intersection(contentWords).isEmpty
            || !words.intersection(composeWords).isEmpty
        return hasIntent
            && !words.intersection(contextWords).isEmpty
    }

    static func isExplicitUIPresentation(
        _ command: String, appName: String,
        bundleID: String? = nil,
        candidates: Set<String> = []
    ) -> Bool {
        guard commandNamesOnlyApp(
            command, appName: appName, candidates: candidates
        ) else {
            return false
        }
        var words = AppMatcher.words(command)
        if !commandAllowsBundleModality(command, bundleID: bundleID) {
            return false
        }
        if words.first == "please" { words.removeFirst() }
        return presentationIntentPrefixes.contains { prefix in
            words.starts(with: prefix)
        }
    }

    static func isAppOnlyPresentation(
        _ command: String, appName: String,
        bundleID: String? = nil,
        candidates: Set<String> = []
    ) -> Bool {
        guard isExplicitUIPresentation(
            command, appName: appName, bundleID: bundleID,
            candidates: candidates
        ) else { return false }
        var words = AppMatcher.words(command)
        if words.first == "please" { words.removeFirst() }
        guard let prefix = presentationIntentPrefixes.first(where: {
            words.starts(with: $0)
        }) else { return false }
        let remainder = words.dropFirst(prefix.count).filter {
            !appOnlyIgnoredWords.contains($0)
        }
        let phrase = remainder.joined(separator: " ")
        if AppMatcher.normalize(phrase) == AppMatcher.normalize(appName) {
            return true
        }
        return remainder.count == 1
            && AppMatcher.bestMatch(for: remainder[0], in: [appName]) != nil
    }

    private static func commandAllowsBundleModality(
        _ command: String, bundleID: String?
    ) -> Bool {
        let hasAddress = command.range(
            of: browserAddressPattern,
            options: [.regularExpression, .caseInsensitive]) != nil
        return (browserModalityWords.isDisjoint(with: AppMatcher.words(command))
            && !hasAddress)
            || ModeCategory.category(forBundleID: bundleID) == .browser
    }

    private static func commandNamesApp(
        _ command: String, appName: String
    ) -> Bool {
        if AppMatcher.bestMatch(for: appName, in: [command]) != nil {
            return true
        }
        return AppMatcher.words(command).contains { word in
            word.count >= Limits.minVerifyTermCharacters
                && !commandMentionWords.contains(word)
                && AppMatcher.bestMatch(for: word, in: [appName]) != nil
        }
    }

    private static func commandNamesOnlyApp(
        _ command: String, appName: String, candidates: Set<String>
    ) -> Bool {
        guard commandNamesApp(command, appName: appName) else { return false }
        let knownApps = candidates.union([appName])
        let exact: [(name: String, range: Range<Int>)] = knownApps.flatMap { name in
            commandAppSpans(command, appName: name).map { (name, $0) }
        }
        if !exact.isEmpty {
            let maximal = exact.filter { item in
                !exact.contains { other in
                    other.range.lowerBound <= item.range.lowerBound
                        && other.range.upperBound >= item.range.upperBound
                        && other.range.count > item.range.count
                }
            }
            let targetIdentity = AppMatcher.normalize(appName)
            let winners = Set(maximal.map { AppMatcher.normalize($0.name) })
            guard winners == [targetIdentity] else { return false }
            let consumed = Set(maximal.flatMap { item -> [Int] in
                guard AppMatcher.normalize(item.name) == targetIdentity else {
                    return []
                }
                return Array(item.range)
            })
            let remainder = AppMatcher.words(command).enumerated().compactMap {
                consumed.contains($0.offset) ? nil : $0.element
            }.joined(separator: " ")
            return !knownApps.contains {
                AppMatcher.normalize($0) != targetIdentity
                    && commandNamesApp(remainder, appName: $0)
            }
        }
        let mentioned = knownApps.filter {
            commandNamesApp(command, appName: $0)
        }
        let identities = Set(mentioned.map(AppMatcher.normalize))
        return identities == [AppMatcher.normalize(appName)]
    }

    private static func commandAppSpans(
        _ command: String, appName: String
    ) -> [Range<Int>] {
        let commandWords = AppMatcher.words(command)
        let targetWords = AppMatcher.words(appName)
        guard !targetWords.isEmpty,
              targetWords.count <= commandWords.count else { return [] }
        let lastStart = commandWords.count - targetWords.count
        return (0...lastStart).compactMap { index in
            Array(commandWords[index..<(index + targetWords.count)])
                == targetWords ? index..<(index + targetWords.count) : nil
        }
    }

    private static func commandMentionsUILabel(
        _ label: String, command: String
    ) -> Bool {
        let labelWords = Set(AppMatcher.words(label))
        let commandWords = Set(AppMatcher.words(command))
        return !labelWords.intersection(commandWords).filter {
            $0.count >= Limits.minVerifyTermCharacters
                && !commandMentionWords.contains($0)
        }.isEmpty
    }

    private static func validatePressUI(
        snapshotID: String, index: Int, role: String, label: String,
        state: BatchState, step: Int
    ) throws {
        guard let snapshot = state.structuredUISnapshot else {
            if state.structuredUIAvailable {
                throw ActionPlanError.invalidStructuredUICapability(step: step)
            }
            return
        }
        guard snapshot.id == snapshotID,
              let element = snapshot.elements.first(where: { $0.index == index }),
              element.role == role,
              AppMatcher.normalize(element.label ?? "")
                == AppMatcher.normalize(label),
              element.enabled else {
            throw ActionPlanError.invalidStructuredUICapability(step: step)
        }
        guard AppMatcher.normalize(label).count
                >= Limits.minPressLabelCharacters,
              !pressLabelIsCommitting(label) else {
            throw ActionPlanError.invalidStructuredUICapability(step: step)
        }
        if !snapshot.complete {
            guard !snapshot.bundleID.isEmpty,
                  !snapshot.windowTitle.isEmpty || snapshot.windowID != nil,
                  commandMentionsUILabel(
                    label, command: state.spokenCommand) else {
                throw ActionPlanError.invalidStructuredUICapability(step: step)
            }
        }
        switch snapshot.source {
        case .cua:
            guard !snapshot.bundleID.isEmpty, snapshot.windowID != nil,
                  element.actions.contains(ActionUICapability.cuaClick) else {
                throw ActionPlanError.invalidStructuredUICapability(step: step)
            }
        case .native:
            let capability = ScreenContext.isEditableActionRole(role)
                ? ActionUICapability.axFocus : ActionUICapability.axPress
            guard !element.actions.contains(ActionUICapability.cuaClick),
                  element.actions.contains(capability) else {
                throw ActionPlanError.invalidStructuredUICapability(step: step)
            }
        case .appNative:
            throw ActionPlanError.invalidStructuredUICapability(step: step)
        }
    }

    private static func hasCuaMediaControl(
        _ state: ActionMediaState,
        snapshot: ActionUISnapshot
    ) -> Bool {
        guard snapshot.source == .cua else { return false }
        return snapshot.elements.contains { element in
            element.enabled
                && element.actions.contains(ActionUICapability.cuaClick)
                && AppMatcher.words(element.label ?? "")
                    .contains(state.rawValue)
        }
    }

    private static func validateVerifyUI(
        snapshotID: String, index: Int, role: String, label: String,
        target: String, purpose: ActionVerificationPurpose,
        state: BatchState, step: Int
    ) throws {
        guard state.requireUITargetVerification,
              let snapshot = state.structuredUISnapshot,
              snapshot.id == snapshotID,
              let element = snapshot.elements.first(where: { $0.index == index }),
              element.role == role,
              AppMatcher.normalize(element.label ?? "")
                == AppMatcher.normalize(label),
              AppMatcher.bestMatch(for: target, in: [label]) != nil
        else { throw ActionPlanError.invalidStructuredUICapability(step: step) }

        switch purpose {
        case .target:
            guard AppMatcher.bestMatch(
                    for: target, in: [state.spokenCommand]) != nil,
                  !snapshot.bundleID.isEmpty,
                  !snapshot.windowTitle.isEmpty || snapshot.windowID != nil,
                  ScreenContext.isEditableActionRole(role)
            else { throw ActionPlanError.invalidStructuredUICapability(step: step) }
            switch snapshot.source {
            case .native:
                guard element.focused else {
                    throw ActionPlanError.invalidStructuredUICapability(step: step)
                }
            case .cua:
                guard snapshot.complete, snapshot.windowID != nil,
                      element.focused, !element.inWebContent,
                      element.actions.contains(ActionUICapability.cuaClick)
                else {
                    throw ActionPlanError.invalidStructuredUICapability(step: step)
                }
            case .appNative:
                throw ActionPlanError.invalidStructuredUICapability(step: step)
            }
            if snapshot.complete,
               !ActionUIEvidencePolicy.mayVerify(
                    index: index, in: snapshot.elements) {
                throw ActionPlanError.invalidStructuredUICapability(step: step)
            }
        case .goal:
            guard snapshot.complete,
                  ActionUIEvidencePolicy.mayVerifyGoal(
                    index: index, source: snapshot.source,
                    in: snapshot.elements)
            else { throw ActionPlanError.invalidStructuredUICapability(step: step) }
        }
    }

    private static func textTarget(
        _ step: [String: Any], state: BatchState, stepIndex: Int
    ) throws -> ActionTextTarget {
        guard let snapshot = state.structuredUISnapshot,
              snapshot.source == .cua, snapshot.windowID != nil,
              let snapshotID = step["snapshot"] as? String,
              snapshotID == snapshot.id,
              let number = step["index"] as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID(),
              !CFNumberIsFloatType(number), number.intValue >= 0,
              let role = step["role"] as? String,
              let label = step["label"] as? String,
              let element = snapshot.elements.first(where: {
                  $0.index == number.intValue
              }),
              element.role == role,
              AppMatcher.normalize(element.label ?? "")
                == AppMatcher.normalize(label),
              element.enabled, !element.inWebContent,
              ScreenContext.isEditableActionRole(role)
        else {
            throw ActionPlanError.invalidStructuredUICapability(
                step: stepIndex)
        }
        return ActionTextTarget(
            snapshotID: snapshotID, index: number.intValue,
            role: role, label: label)
    }

    private static func stateCheck(
        _ step: [String: Any], state: BatchState, stepIndex: Int
    ) throws -> ActionStateCheck {
        guard let snapshot = state.structuredUISnapshot,
              snapshot.source == .cua, snapshot.windowID != nil,
              let snapshotID = step["snapshot"] as? String,
              snapshotID == snapshot.id,
              let number = step["index"] as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID(),
              !CFNumberIsFloatType(number), number.intValue >= 0,
              let role = step["role"] as? String,
              let label = step["label"] as? String,
              let rawAssertion = step["assert"] as? String,
              let assertion = ActionStateAssertion(rawValue: rawAssertion),
              let element = snapshot.elements.first(where: {
                  $0.index == number.intValue
              }),
              element.role == role,
              AppMatcher.normalize(element.label ?? "")
                == AppMatcher.normalize(label),
              element.enabled, !element.inWebContent
        else {
            throw ActionPlanError.invalidStructuredUICapability(
                step: stepIndex)
        }
        let expected = step["expected_value"] as? String
        switch assertion {
        case .writtenText:
            guard ScreenContext.isEditableActionRole(role),
                  !state.pendingValue.isEmpty,
                  expected == state.pendingValue,
                  !label.isEmpty else {
                throw ActionPlanError.invalidStructuredUICapability(
                    step: stepIndex)
            }
        case .selected:
            guard expected == nil, element.selected, !label.isEmpty,
                  ActionPlan.commandMentionsUILabel(
                    label, command: state.spokenCommand) else {
                throw ActionPlanError.invalidStructuredUICapability(
                    step: stepIndex)
            }
        }
        return ActionStateCheck(
            snapshotID: snapshotID, index: number.intValue,
            role: role, label: label, assertion: assertion,
            expectedValue: expected)
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
        var acquiredApp = false
        /// True once text has been typed that a Return would commit, with no
        /// verify_context since it changed or the screen moved. Seeded from
        /// the previous turns.
        var unverifiedText = state.unverifiedText
        /// True while typed text sits where a committing key could deliver it.
        var pendingText = state.pendingText
        var pendingValue = state.pendingValue
        /// Drafts refuse committing keys once text is pending, outright.
        let isDraft = (plan["sends"] as? Bool) == false
        let needsTargetProof = state.requireUITargetVerification
            && (!isDraft || ActionPlan.isRecipientContent(
                state.spokenCommand,
                bundleID: state.structuredUISnapshot?.bundleID))
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
                acquiredApp = true
                steps.append(.openApp(app))
                // Switching apps invalidates any earlier checkpoint: the plan
                // must confirm the app actually came forward before typing —
                // and pending text is unverified again, because its check
                // described a screen this step just left.
                focusEstablished = false
                uiTargetVerified = false
                if pendingText { unverifiedText = true }
                pendingValue = ""

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
                pendingValue = ""

            case "wait_frontmost":
                let requested = step["timeout_ms"] as? Int ?? Limits.defaultWaitMs
                let timeout = min(max(requested, 1), Limits.maxWaitMs)
                let app = String(try string("app").prefix(120))
                appNames.append(app)
                if pendingText,
                   !AppMatcher.namesSameApp(currentApp, app) {
                    pendingValue = ""
                }
                currentApp = app
                acquiredApp = true
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
                let purpose: ActionVerificationPurpose =
                    step["purpose"] as? String == "goal" ? .goal : .target
                let minimumCharacters = purpose == .goal
                    ? Limits.minChangedVerifyCharacters
                    : Limits.minVerifyTermCharacters
                guard AppMatcher.normalize(target).count
                        >= minimumCharacters else {
                    throw ActionPlanError.weakVerifyTerm(target)
                }
                try ActionPlan.validateVerifyUI(
                    snapshotID: snapshotID, index: number.intValue,
                    role: role, label: label, target: target,
                    purpose: purpose, state: state, step: index)
                if purpose == .goal {
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

            case "verify_state":
                guard rawSteps.count == 1, index == 0 else {
                    throw ActionPlanError.invalidStructuredUICapability(
                        step: index)
                }
                steps.append(.verifyState(try ActionPlan.stateCheck(
                    step, state: state, stepIndex: index)))

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
                if verb != "search_text", needsTargetProof,
                   !uiTargetVerified {
                    throw ActionPlanError.contentBeforeTargetVerification(
                        step: index)
                }
                let hasExactTarget = step["snapshot"] != nil
                    || step["index"] != nil || step["role"] != nil
                    || step["label"] != nil
                if state.structuredUISnapshot?.source == .cua,
                   hasExactTarget {
                    let target = try ActionPlan.textTarget(
                        step, state: state, stepIndex: index)
                    let operation: ActionTextOperation
                    switch verb {
                    case "paste_text": operation = .paste
                    case "search_text": operation = .search
                    default: operation = .type
                    }
                    steps.append(.typeTextAt(
                        text: cleaned, operation: operation,
                        target: target))
                    if operation != .search {
                        unverifiedText = true
                        pendingText = true
                        pendingValue += cleaned
                    }
                } else if verb == "search_text" {
                    steps.append(.searchText(cleaned))
                } else {
                    steps.append(verb == "type_text"
                        ? .typeText(cleaned) : .pasteText(cleaned))
                    unverifiedText = true
                    pendingText = true
                    pendingValue += cleaned
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
                    if needsTargetProof, !uiTargetVerified {
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
                    pendingValue = ""
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

            case "media_control":
                guard focusEstablished else {
                    throw ActionPlanError.inputBeforeFocus(step: index)
                }
                guard let rawState = step["state"] as? String,
                      let requested = ActionMediaState(rawValue: rawState),
                      acquiredApp, !currentApp.isEmpty else {
                    throw ActionPlanError.missingField(
                        step: index, field: "state or acquired app")
                }
                guard index == rawSteps.count - 1 else {
                    throw ActionPlanError.pressRequiresFreshObservation(step: index)
                }
                guard let snapshot = state.structuredUISnapshot,
                      AppMatcher.namesSameApp(currentApp, snapshot.appName) else {
                    throw ActionPlanError.invalidStructuredUICapability(step: index)
                }
                let snapshotID = String(try string("snapshot").prefix(80))
                guard snapshot.id == snapshotID else {
                    throw ActionPlanError.invalidStructuredUICapability(step: index)
                }
                if let rawCapability = step["capability"] as? String {
                    let capabilityID = String(rawCapability.prefix(80))
                    guard !capabilityID.isEmpty,
                          !ActionPlan.hasCuaMediaControl(
                            requested, snapshot: snapshot),
                          snapshot.capabilities.contains(where: {
                              $0.id == capabilityID
                                  && $0.verb == .mediaControl
                                  && $0.state == requested
                          }) else {
                        throw ActionPlanError.invalidStructuredUICapability(step: index)
                    }
                    steps.append(.mediaControl(ActionMediaControl(
                        state: requested,
                        capability: .appNative(
                            snapshotID: snapshotID, id: capabilityID))))
                    break
                }
                guard snapshot.source == .cua,
                      let number = step["index"] as? NSNumber,
                      CFGetTypeID(number) != CFBooleanGetTypeID(),
                      !CFNumberIsFloatType(number), number.intValue >= 0 else {
                    throw ActionPlanError.missingField(step: index, field: "index")
                }
                let role = String(try string("role").prefix(40))
                let label = String(ActionPlan.sanitize(try string("label"))
                    .prefix(Limits.maxStructuredUILabelCharacters))
                try ActionPlan.validatePressUI(
                    snapshotID: snapshotID, index: number.intValue,
                    role: role, label: label, state: state, step: index)
                steps.append(.mediaControl(ActionMediaControl(
                    state: requested, snapshotID: snapshotID,
                    index: number.intValue, role: role, label: label)))

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
                if pendingText { pendingValue = "" }

            case "press_ui":
                guard focusEstablished else {
                    throw ActionPlanError.inputBeforeFocus(step: index)
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
                if state.structuredUIAvailable, !state.structuredUIComplete,
                   !ActionPlan.commandMentionsUILabel(
                    label, command: state.spokenCommand) {
                    throw ActionPlanError.partialUIUnmentioned(step: index)
                }
                try ActionPlan.validatePressUI(
                    snapshotID: snapshotID, index: number.intValue,
                    role: role, label: label, state: state, step: index)
                steps.append(.pressUI(
                    snapshotID: snapshotID, index: number.intValue,
                    role: role, label: label))
                focusEstablished = false
                uiTargetVerified = false
                if pendingText { unverifiedText = true }
                if pendingText { pendingValue = "" }

            case "present_ui":
                throw ActionPlanError.invalidUIPresentation(step: index)

            default:
                throw ActionPlanError.unknownVerb(verb)
            }
        }

        state.stepsUsed += steps.count
        state.totalText = totalText
        state.unverifiedText = unverifiedText
        state.pendingText = pendingText
        state.pendingValue = pendingValue
        state.appNames.formUnion(appNames)
        state.currentApp = currentApp

        let goal = (plan["goal"] as? String).map { String(ActionPlan.sanitize($0).prefix(200)) }
        return ActionPlan(goal: goal ?? "",
                          sends: plan["sends"] as? Bool ?? true,
                          steps: steps,
                          unsupported: nil,
                          requiresUITargetVerification:
                              needsTargetProof)
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
                next.pendingValue += text
            case .typeTextAt(let text, let operation, _):
                next.totalText += text.count
                if operation != .search {
                    next.unverifiedText = true
                    next.pendingText = true
                    next.pendingValue += text
                }
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
                    next.pendingValue = ""
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
                next.pendingValue = ""
            case .waitFrontmost(let app, _):
                next.appNames.insert(app)
                // Naming a DIFFERENT app moves the screen: the executor asks
                // that app to come forward when the wait would otherwise time
                // out. Same re-arm as open_app — a verification made about the
                // previous app cannot describe where a Return would land.
                if next.pendingText,
                   !AppMatcher.namesSameApp(next.currentApp, app) {
                    next.unverifiedText = true
                    next.pendingValue = ""
                }
                next.currentApp = app
            case .openURL:
                next.currentApp = ""
                if next.pendingText { next.unverifiedText = true }
                next.pendingValue = ""
            case .pressElement, .pressUI, .presentUI:
                // Navigation that executed moved the screen out from under
                // any pending text; its verification no longer describes
                // where a Return would land.
                if next.pendingText { next.unverifiedText = true }
                if next.pendingText { next.pendingValue = "" }
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
