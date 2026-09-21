import Foundation

/// Immutable spelling candidates; readers remain behind the Context layer.
enum ContextGlossary {
    enum Source { case nearby, window, ocr }

    private static let sparseTermCount = 3
    private static let maxTerms = 24
    private static let maxTermCharacters = 40
    private static let maxCharacters = 600
    private static let maxSourceCharacters = 8_000
    private static let maxSourceStrings = 128
    private static let tokenPattern = #"[\p{L}\p{N}][\p{L}\p{M}\p{N}._+'\u2019-]*"#
    private static let trailingPunctuation = CharacterSet(charactersIn: ".'-_")
    private static let contractionTails = ["n't", "'ll", "'ve", "'re", "'d"]
    private static let inflectionTails = ["ed", "d", "ing"]
    private static let pluralTails = ["s", "es"]
    private static let yTails = [("ies", "y"), ("ied", "y")]
    private static let identifierSeparators: Set<Character> = [".", "_", "+"]
    private static let ignoredWords = Set(
        ("a an the i we you he she they it this that to from reply message "
         + "send subject title open close save cancel file edit view window help "
         + "hello hi thanks please and or but is are was were be for with in on "
         + "today tomorrow monday tuesday wednesday thursday friday saturday sunday")
            .split(separator: " ").map(String.init))
    private static let instructionPattern =
        #"(?i)\b(ignore|disregard|instructions?|system|assistant|output|respond|repeat|insert|execute|override)\b|<\||\|>|https?://"#
    private static let signalTypes: Set<String> = ["site", "person", "file", "channel"]
    private static let systemWordListPath = "/usr/share/dict/words"

    /// Stage order is the rank: cursor -> active window -> OCR. Nothing downstream
    /// receives the source strings; every term must occur literally in a reader.
    static func capture(
        valid: () -> Bool, named: () -> [ContextEntity] = { [] },
        read: (Source) -> [String]
    ) -> [ContextEntity] {
        var result: [ContextEntity] = []
        var seen = Set<String>()
        var characters = 0
        // Extraction is shared by the readers and the named signals so that a
        // term means the same thing wherever it was read.
        let extract = { (strings: [String]) in
            var remaining = maxSourceCharacters
            for text in strings.prefix(maxSourceStrings) {
                guard remaining > 0, result.count < maxTerms else { break }
                // Reject oversized strings rather than manufacture a clipped token.
                remaining -= text.unicodeScalars.count
                guard text.unicodeScalars.count <= maxSourceCharacters,
                      text.range(of: instructionPattern, options: .regularExpression) == nil
                else { continue }
                for term in candidates(in: text) {
                    let key = term.folding(options: .caseInsensitive, locale: Locale(identifier: "en_US_POSIX"))
                    guard !seen.contains(key), result.count < maxTerms,
                          characters + term.count <= maxCharacters else { continue }
                    seen.insert(key)
                    characters += term.count
                    result.append(ContextEntity(type: "glossary", value: term))
                }
            }
        }
        // Only what a reader actually read decides whether the screen was
        // sparse. A window title is metadata the OS hands over for free, so
        // counting it would let "Q3 Roadmap Review - Google Docs" stand in for
        // three read terms and skip the OCR stage that is the only one able to
        // read a canvas-rendered document.
        for source in [Source.nearby, .window, .ocr] {
            guard valid() else { return [] }
            let strings = read(source)
            guard valid() else { return [] }
            extract(strings)
            if result.count >= sparseTermCount { break }
        }
        // Named title/file/person signals rank behind everything a reader
        // produced. Site metadata remains available for mode.
        let namedSignals = Array(named().prefix(maxTerms))
        extract(namedSignals.map(\.value))
        // Preserve existing site-mode and explicit tagging signals, but never a
        // title/subject sentence. These values are also untrusted spelling data,
        // so they are bounded and screened, not reshaped: a channel really is
        // named "#general" and a person really is "Priya Sharma (DM)", and the
        // engine re-validates every value at the socket boundary.
        let signals = namedSignals.filter { entity in
            signalTypes.contains(entity.type)
                && entity.value.count <= maxTermCharacters
                && !entity.value.unicodeScalars.contains(where: {
                    CharacterSet.controlCharacters.contains($0)
                })
        }
        // Validated signals outrank bulk tokens, so they take their budget from
        // the lowest-ranked glossary terms. Otherwise a text-rich screen (a
        // quoted Gmail thread) fills all 24 slots and the site signal that picks
        // the mode, and the file/person/channel signals that resolve @-tags,
        // are silently dropped.
        let signalCharacters = signals.reduce(0) { $0 + $1.value.count }
        while !signals.isEmpty, !result.isEmpty,
              result.count + signals.count > maxTerms
                || characters + signalCharacters > maxCharacters {
            characters -= result.removeLast().value.count
        }
        for signal in signals {
            guard result.count < maxTerms,
                  characters + signal.value.count <= maxCharacters else { continue }
            result.append(signal)
            characters += signal.value.count
        }
        return valid() ? result : []
    }

    /// Shape filtering keeps names/identifiers (Priya, authCheck.ts, kubectl),
    /// not prose. Trailing punctuation is part of the sentence, not the term:
    /// an OCR line break leaves "auto-" and a list leaves "Redis,".
    private static func candidates(in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: tokenPattern) else { return [] }
        let ns = text as NSString
        return regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
            .compactMap { match in
                let term = ns.substring(with: match.range)
                    .replacingOccurrences(of: "\u{2019}", with: "'")
                    .trimmingCharacters(in: trailingPunctuation)
                guard (2...maxTermCharacters).contains(term.unicodeScalars.count),
                      !ignoredWords.contains(term.lowercased()),
                      term.unicodeScalars.contains(where: { CharacterSet.letters.contains($0) }),
                      isTerm(term)
                else { return nil }
                return term
            }
    }

    /// Evidence that a token names something rather than continues a sentence.
    /// A bare hyphen is not evidence: "Follow-up", "sign-in" and "drop-down"
    /// are ordinary wording, and accepting them filled the sparseness quota so
    /// the active-window and OCR stages never ran.
    ///
    ///   Priya, PostgreSQL, v2   -> a capital or a digit
    ///   authCheck.ts, snake_case, c++ -> an identifier separator
    ///   प्रिया, 田中, สมชาย        -> a script with no capital to offer
    ///   kubectl, nginx, pytest  -> a lowercase word the system list lacks
    private static func isTerm(_ term: String) -> Bool {
        if term.contains(where: { $0.isUppercase || $0.isNumber }) { return true }
        if term.contains(where: { identifierSeparators.contains($0) }) { return true }
        if term.lowercased() == term.uppercased() { return true }
        // Without a list there is no evidence either way, so an all-lowercase
        // Latin token falls back to the shape rule: not a term.
        guard let systemWords else { return false }
        return !isOrdinaryWord(term, in: systemWords)
    }

    /// `/usr/share/dict/words` ships with macOS, is read-only, and is byte
    /// identical on every machine, so the same screen yields the same terms
    /// everywhere. The spelling checker's dictionary is the user's own and
    /// mutable: whoever taught macOS "kubectl" would have this feature's exact
    /// jargon rejected, and the selftest assertion would depend on their
    /// learned words and chosen language.
    ///
    /// Nil when the file is missing or unreadable; acceptance degrades to the
    /// shape rule rather than the capture failing.
    static var systemWords: Set<String>? = loadSystemWords(at: systemWordListPath)

    static func loadSystemWords(at path: String) -> Set<String>? {
        guard let data = FileManager.default.contents(atPath: path),
              let text = String(data: data, encoding: .utf8)
        else { return nil }
        var words = Set<String>()
        for line in text.split(separator: "\n") {
            words.insert(line.lowercased())
        }
        return words.isEmpty ? nil : words
    }

    /// The list holds base words only, so a token is ordinary wording when
    /// every part of it is. Splitting keeps the hyphen from being evidence
    /// ("sign-in" is sign + in), and the stem retries keep a plural, a
    /// contraction or an inflection from being evidence ("uses" is use + s,
    /// "doesn't" is does, "deployed" is deploy, "queries" is query,
    /// "committed" is commit). There is deliberately no "-er" rule.
    private static func isOrdinaryWord(_ term: String, in words: Set<String>) -> Bool {
        var lowered = term.lowercased()
        // "doesn't" splits to doesn + t, so the tail comes off before the split.
        if let tail = contractionTails.first(where: { lowered.hasSuffix($0) }) {
            lowered = String(lowered.dropLast(tail.count))
        }
        let parts = lowered.split(whereSeparator: { $0 == "-" || $0 == "'" })
        guard !parts.isEmpty else { return false }
        return parts.allSatisfy { part in
            stems(of: String(part)).contains { words.contains($0) }
        }
    }

    /// Every base form an inflected part could have come from, the part itself
    /// first. Only the caller's word list decides which one is real.
    ///
    ///   fixes     -> fixe, fix          (s, es)
    ///   queries   -> query              (ies -> y)
    ///   verified  -> verifi, verifie, verify  (ed, d, ied -> y)
    ///   committed -> committ, commit    (ed, then the doubled consonant)
    private static func stems(of part: String) -> [String] {
        var out = [part]
        for tail in pluralTails + inflectionTails where part.hasSuffix(tail) {
            let stem = String(part.dropLast(tail.count))
            out.append(stem)
            if inflectionTails.contains(tail), let last = stem.last, stem.dropLast().last == last {
                out.append(String(stem.dropLast()))
            }
        }
        for (tail, base) in yTails where part.hasSuffix(tail) {
            out.append(String(part.dropLast(tail.count)) + base)
        }
        return out
    }
}

/// One-shot asynchronous lifetime; stop only consumes completed work.
final class ContextGlossarySession {
    private let lock = NSLock()
    private let schedule: (@escaping () -> Void) -> Void
    private var generation = UUID()
    private var result: [ContextEntity] = []

    /// Inject scheduling to exercise the same lifetime without timing-based tests.
    init(schedule: ((@escaping () -> Void) -> Void)? = nil) {
        let queue = DispatchQueue(label: "com.velora.glossary", qos: .utility)
        self.schedule = schedule ?? { work in queue.async(execute: work) }
    }

    /// Invalidating before enqueue prevents a prior dictation from contributing.
    func start(_ capture: @escaping (@escaping () -> Bool) -> [ContextEntity]) {
        lock.lock()
        generation = UUID()
        let current = generation
        result = []
        lock.unlock()
        schedule { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let active = self.generation == current
            self.lock.unlock()
            guard active else { return }
            // Readers recheck this lease before AX fallback and screenshot/OCR;
            // stop/cancel must prevent new reads, not only discard their output.
            let captured = capture { [weak self] in
                guard let self else { return false }
                self.lock.lock()
                defer { self.lock.unlock() }
                return self.generation == current
            }
            self.lock.lock()
            defer { self.lock.unlock() }
            guard self.generation == current else { return }
            self.result = captured
        }
    }

    /// No join, semaphore wait, or reader call is permitted on the stop path.
    func take() -> [ContextEntity] {
        lock.lock()
        defer { lock.unlock() }
        let ready = result
        result = []
        generation = UUID()
        return ready
    }

    /// Cancellation discards both ready and late results.
    func cancel() {
        _ = take()
    }
}
