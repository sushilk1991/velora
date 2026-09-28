import Foundation

/// "Play X on YouTube" as a fixed skill: open the results page, press the
/// first video, prove the watch page loaded. The engine's router
/// (`action_skills.py`) writes the plan; these rules re-check it app-side,
/// the same way every other step is validated twice.
///
/// The agent loop could not do this: the first video sits ~940 nodes deep in
/// Chrome's AX tree, past the 500-node snapshot the planner sees (measured
/// 2026-09-28). Owner decision: the command ends with the first result
/// playing.
///
///     open_url https://www.youtube.com/results?search_query=lofi
///     play_first_video   → first /watch link pressed → watch page proven
enum YouTubeSkill {
    static let playVerb = "play_first_video"

    /// A spoken search is a few words; a paragraph is not a video title.
    private static let maxQueryWords = 12
    private static let maxQueryCharacters = 100
    private static let hosts: Set<String> = [
        "youtube.com", "www.youtube.com", "m.youtube.com",
    ]
    private static let resultsPath = "/results"
    private static let queryKey = "search_query"
    private static let watchPath = "/watch"
    private static let videoKey = "v"

    /// The whole command must be one of three shapes, politeness aside:
    /// "open YouTube and play X", "play X on YouTube", "YouTube, play X".
    /// "and", "then", or "and then" may join the first shape's halves.
    /// Mirrors `_YOUTUBE_PLAY` in the engine.
    private static let playPattern = try! NSRegularExpression(  // literal
        pattern: #"""
        ^(?:(?:hey|ok|okay)\s+)?
        (?:(?:can|could|would|will)\s+you\s+)?
        (?:please\s+)?
        (?:
            (?:open|launch|start|go\s+to)\s+youtube\s*,?\s+
                (?:and\s+)?(?:then\s+)?play\s+(.+?)
          | play\s+(.+?)\s+(?:on|in|from)\s+youtube
          | youtube\s*,?\s+play\s+(.+?)
        )
        (?:\s+for\s+me)?(?:\s+please)?$
        """#,
        options: [.caseInsensitive, .allowCommentsAndWhitespace])

    /// A clause break left inside the query joins a second task: a comma
    /// or semicolon, a sentence end followed by more words, or a spaced
    /// dash ("… play lofi. Text it to Priya"). A hyphen inside a word
    /// ("Lo-Fi") is not a break. Mirrors `_CLAUSE_BREAK` in the engine.
    private static let clauseBreak = try! NSRegularExpression(  // literal
        pattern: #"[,;]|[.?!]\s+\S|\s[-\x{2013}\x{2014}]+\s"#)
    /// A conjunction or delivery verb inside the query means a compound
    /// command ("… and share it with Rahul"): the agent loop's.
    private static let compoundWords: Set<String> = [
        "also", "and", "email", "forward", "message", "post", "reply",
        "send", "share", "then",
    ]
    /// "play this video on YouTube" means the video already on screen.
    private static let referenceWords: Set<String> = [
        "current", "first", "it", "last", "my", "next", "previous", "same",
        "that", "the", "these", "this", "those",
    ]
    private static let genericWords: Set<String> = [
        "clip", "music", "one", "song", "songs", "track", "video", "videos",
    ]

    /// The search words of a "play X on YouTube" command, as spoken, or nil.
    ///
    ///     "Can you open YouTube and play lofi for me?"  →  "lofi"
    ///     "play it on YouTube"                          →  nil
    static func playQuery(in command: String) -> String? {
        let text = command.split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
            .trimmingCharacters(in: CharacterSet(charactersIn: ".!?"))
        let whole = NSRange(text.startIndex..., in: text)
        guard let match = playPattern.firstMatch(in: text, range: whole) else {
            return nil
        }

        let raw = (1..<match.numberOfRanges).lazy
            .compactMap { Range(match.range(at: $0), in: text) }
            .first.map { String(text[$0]) } ?? ""
        let query = raw.trimmingCharacters(
            in: CharacterSet(charactersIn: " ,;:\"'"))
        let words = AppMatcher.words(query)
        guard !words.isEmpty, words.count <= maxQueryWords,
              query.count <= maxQueryCharacters else { return nil }
        let queryRange = NSRange(query.startIndex..., in: query)
        guard compoundWords.isDisjoint(with: words),
              clauseBreak.firstMatch(in: query, range: queryRange) == nil
        else { return nil }

        let onlyReferences = words.allSatisfy {
            referenceWords.contains($0) || genericWords.contains($0)
        }
        if onlyReferences, !referenceWords.isDisjoint(with: words) {
            return nil
        }
        return query
    }

    /// A YouTube search results page with a query.
    static func isResultsURL(_ url: URL) -> Bool {
        searchQuery(of: url) != nil
    }

    /// A YouTube watch page: `/watch?v=<id>`.
    static func isWatchURL(_ url: URL) -> Bool {
        guard isYouTube(url),
              let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.path == watchPath
        else { return false }
        return parts.queryItems?.contains {
            $0.name == videoKey && !($0.value ?? "").isEmpty
        } == true
    }

    /// Whether `page` shows the search `opened` asked for. The browser may
    /// re-encode the query ("+" vs "%20"), so the decoded words compare.
    static func sameSearch(_ page: URL, _ opened: URL) -> Bool {
        guard let shown = searchQuery(of: page) else { return false }
        return shown == searchQuery(of: opened)
    }

    /// The decoded, case-folded search words of a results URL.
    private static func searchQuery(of url: URL) -> String? {
        guard url.scheme?.lowercased() == "https", isYouTube(url),
              let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.path == resultsPath,
              let raw = parts.percentEncodedQueryItems?
                .first(where: { $0.name == queryKey })?.value
        else { return nil }

        // Form encoding: "+" is a space, then percent escapes.
        let decoded = raw.replacingOccurrences(of: "+", with: " ")
            .removingPercentEncoding ?? raw
        let words = decoded.lowercased().split(whereSeparator: \.isWhitespace)
        return words.isEmpty ? nil : words.joined(separator: " ")
    }

    private static func isYouTube(_ url: URL) -> Bool {
        hosts.contains(url.host?.lowercased() ?? "")
    }
}

/// What `play_first_video` proved: this browser now shows a watch page.
struct ActionVideoReceipt: Equatable {
    let appName: String
    let bundleID: String
    let watchURL: URL
}
