import CoreFoundation
import Foundation

/// Starting points, not a second kind of saved workflow. Choosing one creates
/// an ordinary unsaved mode, with no app assignments.
struct ModeRecipe: Identifiable {
    let id: String
    let name: String
    let summary: String
    let example: String
    let instructions: String

    var mode: Mode {
        Mode(name: name, prompt: instructions, formatting: "full", apps: [], vocabulary: [], replacements: [])
    }

    static let all: [ModeRecipe] = [
        ModeRecipe(
            id: "work-update", name: "Work update",
            summary: "Turn a spoken update into concise progress, next steps, and blockers.",
            example: "Finished the settings screen today. Next I'll test onboarding. Waiting on the icons.",
            instructions: "Organize the dictated facts as a concise work update. Use Done, Next, and Blocked headings only when the speech provides facts for them. Preserve names, dates, uncertainty, and technical identifiers. Do not invent progress, owners, deadlines, or blockers. Output only the update."),
        ModeRecipe(
            id: "issue-report", name: "Issue report",
            summary: "Structure a bug report using only the details you dictate.",
            example: "Opening settings twice crashes the app. I expected the window to come back. Happened on my Mac this morning.",
            instructions: "Structure the dictated bug report with a short descriptive title and supported sections such as Steps, Expected, and Actual. Include environment details only if dictated. Do not invent reproduction steps, error messages, causes, versions, or fixes. Preserve uncertainty and technical text. Output only the report."),
        ModeRecipe(
            id: "meeting-follow-up", name: "Meeting follow-up",
            summary: "Draft a recap with decisions and actions supported by your words.",
            example: "We agreed to ship Friday. Priya will review the copy. The pricing decision is still open.",
            instructions: "Turn the dictated facts into a concise meeting follow-up. Separate Decisions, Actions, and Open questions when supported. Attribute an owner or deadline only when explicitly dictated. Preserve unresolved questions and uncertainty. Do not invent attendees, commitments, greetings, or a sign-off. Output only the follow-up."),
        ModeRecipe(
            id: "structured-note", name: "Structured note",
            summary: "Keep a longer thought readable with paragraphs and relevant headings.",
            example: "Ideas for onboarding. Start with the shortcut practice. Show the model download progress. Accessibility permission is the part people miss.",
            instructions: "Organize the dictated material into a readable note, with short headings where they clarify the topics. Use bullets for enumerated points and paragraphs for prose. Preserve every substantive fact, caveat, name, number, and technical identifier. Do not add advice, examples, conclusions, or facts not dictated. Output only the note."),
    ]
}

/// A portable, declarative recipe. Local app assignments are deliberately not
/// applied on import; the person reviews the new draft and explicitly saves it.
enum ModeRecipeDocument {
    static let format = "velora-mode"
    static let version = 1
    static let maximumBytes = 256 * 1_024

    struct ValidationError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    static func read(from url: URL) throws -> Mode {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        // Bound the actual read as well as the parsed document, even when a
        // file changes after the picker returns.
        return try decode(handle.read(upToCount: maximumBytes + 1) ?? Data())
    }

    static func decode(_ data: Data) throws -> Mode {
        guard data.count <= maximumBytes else { throw invalid("The recipe is larger than 256 KB.") }
        let object: Any
        do { object = try JSONSerialization.jsonObject(with: data) }
        catch { throw invalid("This file isn't valid JSON. \(error.localizedDescription)") }
        guard let document = object as? [String: Any] else {
            throw invalid("The recipe must be a JSON object.")
        }

        let fields: [String: Any]
        if document["format"] != nil || document["version"] != nil || document["mode"] != nil {
            try knownKeys(document, allowed: ["format", "version", "mode"], label: "recipe")
            guard document["format"] as? String == format else {
                throw invalid("This isn't a Velora mode recipe.")
            }
            guard let number = document["version"] as? NSNumber,
                  CFGetTypeID(number) != CFBooleanGetTypeID(), number.intValue == version,
                  number.doubleValue == Double(version) else {
                throw invalid("This recipe version isn't supported. Use a version 1 recipe.")
            }
            guard let mode = document["mode"] as? [String: Any] else {
                throw invalid("The recipe needs a mode object.")
            }
            fields = mode
        } else {
            // Existing mode JSON is also shareable, without an export step.
            fields = document
        }
        try knownKeys(fields, allowed: ["name", "prompt", "formatting", "apps", "vocabulary", "replacements"], label: "mode")
        let name = try string(fields, "name", maximum: 100, required: true)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw invalid("Give the recipe a name.") }
        let prompt = try string(fields, "prompt", maximum: 16_000)
        let formatting = try string(fields, "formatting", maximum: 16, fallback: "light")
        guard Mode.formattingOptions.contains(formatting) else {
            throw invalid("Formatting must be off, light, or full.")
        }
        _ = try strings(fields, "apps", maximumCount: 256, maximumLength: 256)
        let vocabulary = try strings(fields, "vocabulary", maximumCount: 256, maximumLength: 200)
        var replacements: [Mode.Replacement] = []
        if let value = fields["replacements"] {
            guard let pairs = value as? [String: String], pairs.count <= 256 else {
                throw invalid("Replacements must be an object containing at most 256 text pairs.")
            }
            for key in pairs.keys.sorted() {
                guard !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      key.count <= 200, let value = pairs[key], value.count <= 4_000 else {
                    throw invalid("Replacement phrases must be nonempty and at most 200 characters; replacement text must be at most 4,000 characters.")
                }
                replacements.append(Mode.Replacement(key: key, value: value))
            }
        }
        return Mode(name: name, prompt: prompt, formatting: formatting, apps: [],
                    vocabulary: vocabulary, replacements: replacements)
    }

    static func encode(_ mode: Mode) throws -> Data {
        var replacements: [String: String] = [:]
        for pair in mode.replacements {
            guard replacements[pair.key] == nil else {
                throw invalid("Each heard phrase can have only one replacement before sharing.")
            }
            replacements[pair.key] = pair.value
        }
        let fields: [String: Any] = [
            "name": mode.name, "prompt": mode.prompt, "formatting": mode.formatting,
            "apps": [String](), "vocabulary": mode.vocabulary, "replacements": replacements,
        ]
        let document: [String: Any] = ["format": format, "version": version, "mode": fields]
        let data = try JSONSerialization.data(withJSONObject: document, options: [.prettyPrinted, .sortedKeys])
        _ = try decode(data)
        return data
    }

    private static func invalid(_ message: String) -> ValidationError { ValidationError(message: message) }

    private static func knownKeys(_ fields: [String: Any], allowed: Set<String>, label: String) throws {
        let unknown = Set(fields.keys).subtracting(allowed).sorted()
        guard unknown.isEmpty else {
            throw invalid("Unsupported \(label) fields: \(unknown.joined(separator: ", ")). Recipes contain instructions and text rules only.")
        }
    }

    private static func string(
        _ fields: [String: Any], _ key: String, maximum: Int,
        required: Bool = false, fallback: String = ""
    ) throws -> String {
        guard let value = fields[key] else {
            if required { throw invalid("The recipe needs a \(key).") }
            return fallback
        }
        guard let text = value as? String, text.count <= maximum else {
            throw invalid("\(key.capitalized) must be text with at most \(maximum) characters.")
        }
        return text
    }

    private static func strings(
        _ fields: [String: Any], _ key: String, maximumCount: Int, maximumLength: Int
    ) throws -> [String] {
        guard let value = fields[key] else { return [] }
        guard let list = value as? [String], list.count <= maximumCount,
              list.allSatisfy({ $0.count <= maximumLength }) else {
            throw invalid("\(key.capitalized) must be a list of at most \(maximumCount) text entries, each at most \(maximumLength) characters.")
        }
        return list
    }
}
