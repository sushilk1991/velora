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
    private static let tokenPattern = #"[\p{L}\p{N}][\p{L}\p{M}\p{N}._+'-]*"#
    private static let ignoredWords = Set(
        ("a an the i we you he she they it this that to from reply message "
         + "send subject title open close save cancel file edit view window help "
         + "hello hi thanks please and or but is are was were be for with in on "
         + "today tomorrow monday tuesday wednesday thursday friday saturday sunday")
            .split(separator: " ").map(String.init))
    private static let instructionPattern =
        #"(?i)\b(ignore|disregard|instructions?|system|assistant|output|respond|repeat|insert|execute|override)\b|<\||\|>|https?://"#

    /// Stage order is the rank: cursor -> active window -> OCR. Nothing downstream
    /// receives the source strings; every term must occur literally in a reader.
    static func capture(
        valid: () -> Bool, named: () -> [ContextEntity] = { [] },
        read: (Source) -> [String]
    ) -> [ContextEntity] {
        var result: [ContextEntity] = []
        var seen = Set<String>()
        var characters = 0
        var namedSignals: [ContextEntity] = []
        for source in [Source.nearby, .window, .ocr] {
            guard valid() else { return [] }
            var strings = read(source)
            guard valid() else { return [] }
            // Named title/file/person signals rank behind the cursor and ahead
            // of broad window text. Site metadata remains available for mode.
            if source == .nearby {
                namedSignals = Array(named().prefix(maxTerms))
                strings.append(contentsOf: namedSignals.map(\.value))
            }
            var remaining = maxSourceCharacters
            for text in strings.prefix(maxSourceStrings) {
                guard remaining > 0 else { break }
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
            if result.count >= sparseTermCount { break }
        }
        // Preserve existing site-mode and explicit tagging signals, but never a
        // title/subject sentence. These values are also untrusted spelling data.
        let signals = namedSignals.filter { entity in
            if entity.type == "site" { return entity.value.count <= maxTermCharacters }
            guard ["person", "file", "channel"].contains(entity.type),
                  entity.value.count <= maxTermCharacters,
                  entity.value.range(of: instructionPattern, options: .regularExpression) == nil
            else { return false }
            return candidates(in: entity.value).joined(separator: " ") == entity.value
        }
        for signal in signals {
            guard result.count < maxTerms,
                  characters + signal.value.count <= maxCharacters else { continue }
            result.append(signal)
            characters += signal.value.count
        }
        return valid() ? result : []
    }

    /// Shape filtering keeps names/identifiers (Priya, authCheck.ts), not prose.
    private static func candidates(in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: tokenPattern) else { return [] }
        let ns = text as NSString
        return regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
            .compactMap { match in
                let term = ns.substring(with: match.range).trimmingCharacters(in: CharacterSet(charactersIn: ".'"))
                guard (2...maxTermCharacters).contains(term.unicodeScalars.count),
                      !ignoredWords.contains(term.lowercased()),
                      term.unicodeScalars.contains(where: { CharacterSet.letters.contains($0) }),
                      term.contains(where: { $0.isUppercase || $0.isNumber })
                        || term.contains(where: { "._+-".contains($0) })
                else { return nil }
                return term
            }
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

    /// Cancellation and setting revocation discard both ready and late results.
    func cancel() {
        _ = take()
    }
}
