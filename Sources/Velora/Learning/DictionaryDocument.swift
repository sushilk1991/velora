import Foundation

enum DictionaryValidationError: Error, Equatable, LocalizedError {
    case empty
    case controlCharacter
    case tooLong
    case invalidEntry
    case logicalKeyChanged
    case unsupportedSchema(Int)
    case tooManyEntries

    var errorDescription: String? {
        switch self {
        case .empty: return "Enter a word or phrase."
        case .controlCharacter: return "Words cannot contain line breaks or control characters."
        case .tooLong: return "Words and phrases can be at most 60 characters."
        case .invalidEntry: return "This dictionary entry is invalid."
        case .logicalKeyChanged: return "Re-adding an entry cannot change what it matches."
        case .unsupportedSchema(let version):
            return "This dictionary was created by a newer Velora version (schema \(version))."
        case .tooManyEntries: return "This dictionary contains too many entries."
        }
    }
}

/// A prompt-safe term or phrase. Validation happens at the domain boundary so
/// manual input, imports, migrations, and cloud documents obey the same rules.
struct DictionaryValue: Codable, Equatable, Hashable {
    static let maximumLength = 60

    let text: String

    var normalized: String {
        text.lowercased(with: Locale(identifier: "en_US_POSIX"))
    }

    init(_ rawValue: String) throws {
        if rawValue.unicodeScalars.contains(where: { scalar in
            CharacterSet.controlCharacters.contains(scalar)
        }) {
            throw DictionaryValidationError.controlCharacter
        }
        let compact = rawValue.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        guard !compact.isEmpty else { throw DictionaryValidationError.empty }
        guard compact.count <= Self.maximumLength else { throw DictionaryValidationError.tooLong }
        text = compact
    }

    init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        try self.init(value)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(text)
    }
}

enum DictionaryEntryKind: String, Codable, CaseIterable {
    case manualTerm = "manual_term"
    case manualReplacement = "manual_replacement"
    case learnedHard = "learned_hard"
    case learnedSoft = "learned_soft"
    case autoTerm = "auto_term"
    case autoBan = "auto_ban"
}

enum DictionaryNamespace: String, Codable, CaseIterable {
    case manual
    case learned
    case auto
}

struct DictionaryEntry: Codable, Equatable, Identifiable {
    let logicalKey: String
    let kind: DictionaryEntryKind
    let writeAs: String
    let heardAs: String?
    let epoch: Int
    let revision: Int
    let generation: Int
    let modifiedAt: Date
    let deviceID: String
    let deleted: Bool

    var id: String { logicalKey }

    var namespace: DictionaryNamespace {
        switch kind {
        case .manualTerm, .manualReplacement: return .manual
        case .learnedHard, .learnedSoft: return .learned
        case .autoTerm, .autoBan: return .auto
        }
    }

    private enum CodingKeys: String, CodingKey {
        case logicalKey = "logical_key"
        case kind
        case writeAs = "write_as"
        case heardAs = "heard_as"
        case epoch
        case revision
        case generation
        case modifiedAt = "modified_at"
        case deviceID = "device_id"
        case deleted
    }

    private init(
        logicalKey: String,
        kind: DictionaryEntryKind,
        writeAs: String,
        heardAs: String?,
        epoch: Int,
        revision: Int,
        generation: Int,
        modifiedAt: Date,
        deviceID: String,
        deleted: Bool
    ) throws {
        let written = try DictionaryValue(writeAs)
        let heard = try heardAs.map(DictionaryValue.init)
        guard !deviceID.isEmpty, epoch >= 0, revision >= 0, generation >= 0 else {
            throw DictionaryValidationError.invalidEntry
        }
        let expectedKey = Self.makeLogicalKey(kind: kind, writeAs: written, heardAs: heard)
        guard expectedKey == logicalKey else { throw DictionaryValidationError.invalidEntry }
        self.logicalKey = logicalKey
        self.kind = kind
        self.writeAs = written.text
        self.heardAs = heard?.text
        self.epoch = epoch
        self.revision = revision
        self.generation = generation
        self.modifiedAt = modifiedAt
        self.deviceID = deviceID
        self.deleted = deleted
    }

    static func manual(
        writeAs: String,
        heardAs: String? = nil,
        deviceID: String,
        at date: Date,
        epoch: Int = 0,
        revision: Int = 1,
        generation: Int = 0
    ) throws -> DictionaryEntry {
        let written = try DictionaryValue(writeAs)
        let heard = try heardAs.map(DictionaryValue.init)
        let kind: DictionaryEntryKind = heard == nil ? .manualTerm : .manualReplacement
        return try DictionaryEntry(
            logicalKey: makeLogicalKey(kind: kind, writeAs: written, heardAs: heard),
            kind: kind,
            writeAs: written.text,
            heardAs: heard?.text,
            epoch: epoch,
            revision: revision,
            generation: generation,
            modifiedAt: date,
            deviceID: deviceID,
            deleted: false)
    }

    static func learned(
        wrong: String,
        right: String,
        soft: Bool,
        deviceID: String,
        at date: Date,
        epoch: Int = 0,
        revision: Int = 1,
        generation: Int = 0
    ) throws -> DictionaryEntry {
        let written = try DictionaryValue(right)
        let heard = try DictionaryValue(wrong)
        let kind: DictionaryEntryKind = soft ? .learnedSoft : .learnedHard
        return try DictionaryEntry(
            logicalKey: makeLogicalKey(kind: kind, writeAs: written, heardAs: heard),
            kind: kind,
            writeAs: written.text,
            heardAs: heard.text,
            epoch: epoch,
            revision: revision,
            generation: generation,
            modifiedAt: date,
            deviceID: deviceID,
            deleted: false)
    }

    static func automatic(
        term: String,
        banned: Bool,
        deviceID: String,
        at date: Date,
        epoch: Int = 0,
        revision: Int = 1,
        generation: Int = 0
    ) throws -> DictionaryEntry {
        let written = try DictionaryValue(term)
        let kind: DictionaryEntryKind = banned ? .autoBan : .autoTerm
        return try DictionaryEntry(
            logicalKey: makeLogicalKey(kind: kind, writeAs: written, heardAs: nil),
            kind: kind,
            writeAs: written.text,
            heardAs: nil,
            epoch: epoch,
            revision: revision,
            generation: generation,
            modifiedAt: date,
            deviceID: deviceID,
            deleted: false)
    }

    func deleting(deviceID: String, at date: Date) -> DictionaryEntry {
        try! DictionaryEntry(
            logicalKey: logicalKey,
            kind: kind,
            writeAs: writeAs,
            heardAs: heardAs,
            epoch: epoch,
            revision: revision + 1,
            generation: generation,
            modifiedAt: date,
            deviceID: deviceID,
            deleted: true)
    }

    func readding(writeAs: String, deviceID: String, at date: Date) throws -> DictionaryEntry {
        let written = try DictionaryValue(writeAs)
        let expected = Self.makeLogicalKey(
            kind: kind, writeAs: written, heardAs: try heardAs.map(DictionaryValue.init))
        guard expected == logicalKey else { throw DictionaryValidationError.logicalKeyChanged }
        return try DictionaryEntry(
            logicalKey: logicalKey,
            kind: kind,
            writeAs: written.text,
            heardAs: heardAs,
            epoch: epoch + 1,
            revision: 1,
            generation: generation,
            modifiedAt: date,
            deviceID: deviceID,
            deleted: false)
    }

    func revising(writeAs: String, deviceID: String, at date: Date) throws -> DictionaryEntry {
        let written = try DictionaryValue(writeAs)
        let expected = Self.makeLogicalKey(
            kind: kind, writeAs: written, heardAs: try heardAs.map(DictionaryValue.init))
        guard expected == logicalKey else { throw DictionaryValidationError.logicalKeyChanged }
        return try DictionaryEntry(
            logicalKey: logicalKey,
            kind: kind,
            writeAs: written.text,
            heardAs: heardAs,
            epoch: epoch,
            revision: revision + 1,
            generation: generation,
            modifiedAt: date,
            deviceID: deviceID,
            deleted: false)
    }

    func withGeneration(_ generation: Int) -> DictionaryEntry {
        try! DictionaryEntry(
            logicalKey: logicalKey,
            kind: kind,
            writeAs: writeAs,
            heardAs: heardAs,
            epoch: epoch,
            revision: revision,
            generation: generation,
            modifiedAt: modifiedAt,
            deviceID: deviceID,
            deleted: deleted)
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            logicalKey: values.decode(String.self, forKey: .logicalKey),
            kind: values.decode(DictionaryEntryKind.self, forKey: .kind),
            writeAs: values.decode(String.self, forKey: .writeAs),
            heardAs: values.decodeIfPresent(String.self, forKey: .heardAs),
            epoch: values.decode(Int.self, forKey: .epoch),
            revision: values.decode(Int.self, forKey: .revision),
            generation: values.decode(Int.self, forKey: .generation),
            modifiedAt: values.decode(Date.self, forKey: .modifiedAt),
            deviceID: values.decode(String.self, forKey: .deviceID),
            deleted: values.decode(Bool.self, forKey: .deleted))
    }

    private static func makeLogicalKey(
        kind: DictionaryEntryKind,
        writeAs: DictionaryValue,
        heardAs: DictionaryValue?
    ) -> String {
        let matchValue: String
        switch kind {
        case .manualReplacement, .learnedHard, .learnedSoft:
            matchValue = heardAs?.normalized ?? ""
        case .manualTerm, .autoTerm, .autoBan:
            matchValue = writeAs.normalized
        }
        return "\(kind.rawValue):\(matchValue)"
    }
}

struct DictionaryProjection: Equatable {
    var vocabulary: [String]
    var replacements: [String: String]
    var softReplacements: [String: String]
    var autoTerms: [String]
    var autoBanned: [String]
}

struct DictionaryDocument: Codable, Equatable {
    static let currentSchemaVersion = 1
    static let maximumEntries = 2_000

    let schemaVersion: Int
    private(set) var entries: [DictionaryEntry]
    private(set) var clearGenerations: [DictionaryNamespace: Int]
    private(set) var clearModifiedAt: [DictionaryNamespace: Date]

    private enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case entries
        case clearGenerations = "clear_generations"
        case clearModifiedAt = "clear_modified_at"
    }

    init(
        entries: [DictionaryEntry] = [],
        clearGenerations: [DictionaryNamespace: Int] = [:],
        clearModifiedAt: [DictionaryNamespace: Date] = [:]
    ) {
        schemaVersion = Self.currentSchemaVersion
        self.clearGenerations = clearGenerations
        self.clearModifiedAt = clearModifiedAt
        self.entries = Self.collapsed(entries)
    }

    var activeEntries: [DictionaryEntry] {
        entries.filter(isActive).sorted { $0.logicalKey < $1.logicalKey }
    }

    func isActive(_ entry: DictionaryEntry) -> Bool {
        guard !entry.deleted else { return false }
        let generation = clearGenerations[entry.namespace] ?? 0
        if entry.generation >= generation { return true }
        guard let clearedAt = clearModifiedAt[entry.namespace] else { return false }
        return entry.modifiedAt > clearedAt
    }

    func entry(id: String) -> DictionaryEntry? {
        entries.first { $0.logicalKey == id }
    }

    func generation(for namespace: DictionaryNamespace) -> Int {
        clearGenerations[namespace] ?? 0
    }

    func upserting(_ entry: DictionaryEntry) -> DictionaryDocument {
        DictionaryDocument(
            entries: entries + [entry],
            clearGenerations: clearGenerations,
            clearModifiedAt: clearModifiedAt)
    }

    var effectiveProjection: DictionaryProjection {
        let active = activeEntries
        let banned = Set(active.filter { $0.kind == .autoBan }.map {
            $0.writeAs.lowercased(with: Locale(identifier: "en_US_POSIX"))
        })

        var replacements: [String: String] = [:]
        var soft: [String: String] = [:]
        var vocabulary: [String] = []
        var seenVocabulary: Set<String> = []

        func appendVocabulary(_ term: String) {
            let key = term.lowercased(with: Locale(identifier: "en_US_POSIX"))
            guard seenVocabulary.insert(key).inserted else { return }
            vocabulary.append(term)
        }

        let priority: [DictionaryEntryKind: Int] = [
            .manualReplacement: 0, .manualTerm: 0,
            .learnedHard: 1, .learnedSoft: 1,
            .autoTerm: 2, .autoBan: 2,
        ]
        for entry in active.sorted(by: {
            let left = priority[$0.kind] ?? 9
            let right = priority[$1.kind] ?? 9
            return left == right ? $0.logicalKey < $1.logicalKey : left < right
        }) {
            switch entry.kind {
            case .manualReplacement, .learnedHard:
                if let heard = entry.heardAs {
                    let key = heard.lowercased(with: Locale(identifier: "en_US_POSIX"))
                    if replacements[key] == nil && soft[key] == nil { replacements[key] = entry.writeAs }
                }
                appendVocabulary(entry.writeAs)
            case .learnedSoft:
                if let heard = entry.heardAs {
                    let key = heard.lowercased(with: Locale(identifier: "en_US_POSIX"))
                    if replacements[key] == nil && soft[key] == nil { soft[key] = entry.writeAs }
                }
                appendVocabulary(entry.writeAs)
            case .manualTerm:
                appendVocabulary(entry.writeAs)
            case .autoTerm:
                let key = entry.writeAs.lowercased(with: Locale(identifier: "en_US_POSIX"))
                if !banned.contains(key) { appendVocabulary(entry.writeAs) }
            case .autoBan:
                break
            }
        }

        return DictionaryProjection(
            vocabulary: vocabulary,
            replacements: replacements,
            softReplacements: soft,
            autoTerms: active.filter { entry in
                entry.kind == .autoTerm && !banned.contains(
                    entry.writeAs.lowercased(with: Locale(identifier: "en_US_POSIX")))
            }.map(\.writeAs),
            autoBanned: active.filter { $0.kind == .autoBan }.map(\.writeAs))
    }

    func merged(with other: DictionaryDocument) -> DictionaryDocument {
        var generations: [DictionaryNamespace: Int] = [:]
        var modifiedAt: [DictionaryNamespace: Date] = [:]
        for namespace in DictionaryNamespace.allCases {
            let leftGeneration = clearGenerations[namespace] ?? 0
            let rightGeneration = other.clearGenerations[namespace] ?? 0
            let generation = max(leftGeneration, rightGeneration)
            if generation > 0 {
                generations[namespace] = generation
                let dates = [
                    leftGeneration == generation ? clearModifiedAt[namespace] : nil,
                    rightGeneration == generation ? other.clearModifiedAt[namespace] : nil,
                ].compactMap { $0 }
                if let latest = dates.max() { modifiedAt[namespace] = latest }
            }
        }
        return DictionaryDocument(
            entries: entries + other.entries,
            clearGenerations: generations,
            clearModifiedAt: modifiedAt)
    }

    func clearing(
        _ namespace: DictionaryNamespace,
        deviceID _: String,
        at date: Date
    ) -> DictionaryDocument {
        var generations = clearGenerations
        var modifiedAt = clearModifiedAt
        generations[namespace, default: 0] += 1
        modifiedAt[namespace] = date
        return DictionaryDocument(
            entries: entries,
            clearGenerations: generations,
            clearModifiedAt: modifiedAt)
    }

    func encoded() throws -> Data {
        guard entries.count <= Self.maximumEntries else {
            throw DictionaryValidationError.tooManyEntries
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(self)
    }

    static func decode(_ data: Data) throws -> DictionaryDocument {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let document = try decoder.decode(DictionaryDocument.self, from: data)
        guard document.schemaVersion == currentSchemaVersion else {
            throw DictionaryValidationError.unsupportedSchema(document.schemaVersion)
        }
        guard document.entries.count <= maximumEntries else {
            throw DictionaryValidationError.tooManyEntries
        }
        return document
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try values.decode(Int.self, forKey: .schemaVersion)
        entries = Self.collapsed(try values.decode([DictionaryEntry].self, forKey: .entries))
        let wireGenerations = try values.decodeIfPresent(
            [String: Int].self, forKey: .clearGenerations) ?? [:]
        let decodedGenerations: [DictionaryNamespace: Int] = Dictionary(
            uniqueKeysWithValues: wireGenerations.compactMap { key, value in
            guard let namespace = DictionaryNamespace(rawValue: key), value >= 0 else { return nil }
            return (namespace, value)
        })
        clearGenerations = decodedGenerations
        let wireDates = try values.decodeIfPresent(
            [String: Date].self, forKey: .clearModifiedAt) ?? [:]
        clearModifiedAt = Dictionary(uniqueKeysWithValues: wireDates.compactMap { key, value in
            guard let namespace = DictionaryNamespace(rawValue: key),
                  (decodedGenerations[namespace] ?? 0) > 0 else { return nil }
            return (namespace, value)
        })
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(schemaVersion, forKey: .schemaVersion)
        try values.encode(entries.sorted { $0.logicalKey < $1.logicalKey }, forKey: .entries)
        try values.encode(Dictionary(uniqueKeysWithValues: clearGenerations.map {
            ($0.key.rawValue, $0.value)
        }), forKey: .clearGenerations)
        try values.encode(Dictionary(uniqueKeysWithValues: clearModifiedAt.map {
            ($0.key.rawValue, $0.value)
        }), forKey: .clearModifiedAt)
    }

    private static func collapsed(_ entries: [DictionaryEntry]) -> [DictionaryEntry] {
        var byKey: [String: DictionaryEntry] = [:]
        for entry in entries {
            if let existing = byKey[entry.logicalKey] {
                byKey[entry.logicalKey] = winner(existing, entry)
            } else {
                byKey[entry.logicalKey] = entry
            }
        }
        return byKey.values.sorted { $0.logicalKey < $1.logicalKey }
    }

    private static func winner(_ left: DictionaryEntry, _ right: DictionaryEntry) -> DictionaryEntry {
        if left.epoch != right.epoch { return left.epoch > right.epoch ? left : right }
        if left.deleted != right.deleted { return left.deleted ? left : right }
        if left.revision != right.revision { return left.revision > right.revision ? left : right }
        if left.modifiedAt != right.modifiedAt { return left.modifiedAt > right.modifiedAt ? left : right }
        if left.deviceID != right.deviceID { return left.deviceID > right.deviceID ? left : right }
        let leftValue = "\(left.kind.rawValue)|\(left.writeAs)|\(left.heardAs ?? "")"
        let rightValue = "\(right.kind.rawValue)|\(right.writeAs)|\(right.heardAs ?? "")"
        return leftValue >= rightValue ? left : right
    }
}
