import Foundation

enum CLICommand: Equatable {
    case status
    case recent(limit: Int)
    case search(query: String, limit: Int)
    case stats
    case transcribe(path: String, mode: String?)
    case listen(mode: String?)
    /// Plan a spoken-style command; `execute` actually carries it out.
    case action(text: String, execute: Bool, allowSend: Bool)
    /// Diagnostic: dump the frontmost app's accessibility tree.
    case axProbe
    case mcp
    case workflow(name: String, arguments: [String: String])
}

struct CLIInvocation: Equatable {
    let command: CLICommand
    let json: Bool

    enum ParseError: LocalizedError {
        case missingCommand
        case unknownCommand(String)
        case missingQuery
        case missingPath
        case missingActionText
        case missingOptionValue(String)
        case invalidOption(String)
        case invalidLimit

        var errorDescription: String? {
            switch self {
            case .missingCommand: return "Missing command"
            case .unknownCommand(let value): return "Unknown command: \(value)"
            case .missingQuery: return "search requires a query"
            case .missingPath: return "transcribe requires an audio file path"
            case .missingActionText: return "action requires a command to carry out"
            case .missingOptionValue(let value): return "\(value) requires a value"
            case .invalidOption(let value): return "Unknown option: \(value)"
            case .invalidLimit: return "--limit requires a positive integer"
            }
        }
    }

    static func parse(_ raw: [String]) throws -> CLIInvocation {
        var arguments = raw.filter { $0 != "--cli" }
        let json = arguments.contains("--json")
        arguments.removeAll { $0 == "--json" }
        guard let name = arguments.first else { throw ParseError.missingCommand }
        arguments.removeFirst()

        switch name {
        case "status":
            guard arguments.isEmpty else { throw ParseError.invalidOption(arguments[0]) }
            return CLIInvocation(command: .status, json: json)
        case "stats":
            guard arguments.isEmpty else { throw ParseError.invalidOption(arguments[0]) }
            return CLIInvocation(command: .stats, json: json)
        case "mcp":
            guard arguments.isEmpty else { throw ParseError.invalidOption(arguments[0]) }
            return CLIInvocation(command: .mcp, json: false)
        case "recent":
            let limit = try parseLimit(arguments, defaultValue: 10)
            return CLIInvocation(command: .recent(limit: limit), json: json)
        case "search":
            var queryParts: [String] = []
            var limit = 10
            var index = 0
            while index < arguments.count {
                if arguments[index] == "--limit" {
                    guard index + 1 < arguments.count,
                          let parsed = Int(arguments[index + 1]), parsed > 0
                    else { throw ParseError.invalidLimit }
                    limit = min(parsed, LocalControlRouter.maxResults)
                    index += 2
                } else if arguments[index].hasPrefix("--") {
                    throw ParseError.invalidOption(arguments[index])
                } else {
                    queryParts.append(arguments[index])
                    index += 1
                }
            }
            let query = queryParts.joined(separator: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !query.isEmpty else { throw ParseError.missingQuery }
            return CLIInvocation(
                command: .search(query: query, limit: limit), json: json)
        case "transcribe":
            var path: String?
            var mode: String?
            var index = 0
            while index < arguments.count {
                if arguments[index] == "--mode" {
                    guard index + 1 < arguments.count else {
                        throw ParseError.missingOptionValue("--mode")
                    }
                    mode = arguments[index + 1]
                    index += 2
                } else if arguments[index].hasPrefix("--") {
                    throw ParseError.invalidOption(arguments[index])
                } else if path == nil {
                    path = arguments[index]
                    index += 1
                } else {
                    throw ParseError.invalidOption(arguments[index])
                }
            }
            guard let path, !path.isEmpty else { throw ParseError.missingPath }
            return CLIInvocation(command: .transcribe(path: path, mode: mode), json: json)
        case "listen":
            var mode: String?
            guard arguments.count <= 2 else {
                throw ParseError.invalidOption(arguments.last ?? "")
            }
            if !arguments.isEmpty {
                guard arguments[0] == "--mode" else {
                    throw ParseError.invalidOption(arguments[0])
                }
                guard arguments.count == 2 else {
                    throw ParseError.missingOptionValue("--mode")
                }
                mode = arguments[1]
            }
            return CLIInvocation(command: .listen(mode: mode), json: json)
        case "ax-probe":
            guard arguments.isEmpty else { throw ParseError.invalidOption(arguments[0]) }
            return CLIInvocation(command: .axProbe, json: true)
        case "action":
            var execute = false
            var allowSend = false
            var words: [String] = []
            for argument in arguments {
                if argument == "--execute" { execute = true }
                else if argument == "--allow-send" { execute = true; allowSend = true }
                else if argument.hasPrefix("--") { throw ParseError.invalidOption(argument) }
                else { words.append(argument) }
            }
            let text = words.joined(separator: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { throw ParseError.missingActionText }
            return CLIInvocation(
                command: .action(text: text, execute: execute, allowSend: allowSend),
                json: json)
        case "modes", "vocabulary", "meetings", "format", "model", "paste-last":
            return CLIInvocation(command: try parseWorkflow(name, arguments), json: json)
        default:
            throw ParseError.unknownCommand(name)
        }
    }

    private static func parseWorkflow(_ name: String, _ arguments: [String]) throws -> CLICommand {
        func options(_ raw: [String], values: Set<String> = [], flags: Set<String> = []) throws -> ([String], [String: String]) {
            var words: [String] = [], result: [String: String] = [:]
            var index = 0
            while index < raw.count {
                let token = raw[index]
                if token.hasPrefix("--") {
                    guard result[token] == nil else { throw ParseError.invalidOption(token) }
                    if flags.contains(token) { result[token] = "true" }
                    else if values.contains(token) {
                        guard index + 1 < raw.count else { throw ParseError.missingOptionValue(token) }
                        index += 1; result[token] = raw[index]
                    } else { throw ParseError.invalidOption(token) }
                } else { words.append(token) }
                index += 1
            }
            if let rawLimit = result["--limit"] {
                guard let value = Int(rawLimit), value > 0 else { throw ParseError.invalidLimit }
                result["--limit"] = String(min(100, value))
            }
            return (words, Dictionary(uniqueKeysWithValues: result.map { (String($0.key.dropFirst(2)).replacingOccurrences(of: "-", with: "_"), $0.value) }))
        }
        func one(_ words: [String]) throws -> String {
            guard words.count == 1, !words[0].isEmpty else { throw ParseError.missingQuery }
            return words[0]
        }
        if name == "format" {
            let (words, values) = try options(arguments, values: ["--mode", "--file"])
            var payload = values
            if let file = payload.removeValue(forKey: "file") {
                guard words.isEmpty else { throw ParseError.invalidOption("Use text or --file, not both") }
                payload["text_file"] = file
            } else {
                let text = words.joined(separator: " ")
                guard !text.isEmpty else { throw ParseError.missingQuery }
                payload["text"] = text
            }
            return .workflow(name: "format_text", arguments: payload)
        }
        if name == "model" {
            guard arguments.isEmpty || arguments == ["status"] else { throw ParseError.invalidOption(arguments[0]) }
            return .workflow(name: "model_status", arguments: [:])
        }
        if name == "paste-last" {
            let (words, values) = try options(arguments, values: ["--target"], flags: ["--copy", "--paste"])
            guard words.isEmpty, (values["copy"] != nil) != (values["paste"] != nil) else {
                throw ParseError.invalidOption("Choose exactly one of --copy or --paste")
            }
            if values["paste"] != nil {
                guard let target = values["target"], !target.isEmpty else { throw ParseError.missingOptionValue("--target") }
                return .workflow(name: "paste_last", arguments: ["delivery": "paste", "target_bundle_id": target])
            }
            guard values["target"] == nil else { throw ParseError.invalidOption("--target") }
            return .workflow(name: "paste_last", arguments: ["delivery": "copy"])
        }
        var remaining = arguments
        let verb = remaining.isEmpty ? "list" : remaining.removeFirst()
        switch (name, verb) {
        case ("modes", "list"), ("vocabulary", "list"), ("meetings", "list"):
            let (words, values) = try options(remaining, values: ["--limit"])
            guard words.isEmpty else { throw ParseError.invalidOption(words[0]) }
            return .workflow(name: name + "_list", arguments: values)
        case ("modes", "validate"):
            return .workflow(name: "modes_validate", arguments: ["recipe_file": try one(remaining)])
        case ("modes", "init"):
            let (words, values) = try options(remaining, values: ["--recipe"])
            var payload = values
            payload["name"] = words.isEmpty ? "Custom mode" : words.joined(separator: " ")
            return .workflow(name: "modes_init", arguments: payload)
        case ("vocabulary", "add"):
            let (words, values) = try options(remaining, values: ["--heard-as"])
            guard !words.isEmpty else { throw ParseError.missingQuery }
            var payload = values; payload["write_as"] = words.joined(separator: " ")
            return .workflow(name: "vocabulary_add", arguments: payload)
        case ("vocabulary", "remove"):
            let (words, values) = try options(remaining, flags: ["--yes"])
            guard values["yes"] != nil else { throw ParseError.invalidOption("Removing vocabulary requires --yes") }
            return .workflow(name: "vocabulary_remove", arguments: ["entry_id": try one(words), "confirm": "true"])
        case ("meetings", "search"):
            let (words, values) = try options(remaining, values: ["--limit"])
            guard !words.isEmpty else { throw ParseError.missingQuery }
            var payload = values; payload["query"] = words.joined(separator: " ")
            return .workflow(name: "meetings_search", arguments: payload)
        case ("meetings", "show"):
            let (words, values) = try options(remaining, values: ["--limit"])
            var payload = values; payload["meeting_id"] = try one(words)
            return .workflow(name: "meetings_show", arguments: payload)
        case ("meetings", "export"):
            let (words, values) = try options(remaining, values: ["--format"])
            let format = values["format"] ?? "markdown"
            guard ["markdown", "text", "srt", "vtt"].contains(format) else { throw ParseError.invalidOption("--format") }
            return .workflow(name: "meetings_export", arguments: ["meeting_id": try one(words), "format": format])
        default: throw ParseError.unknownCommand(name + " " + verb)
        }
    }

    private static func parseLimit(_ arguments: [String], defaultValue: Int) throws -> Int {
        guard !arguments.isEmpty else { return defaultValue }
        guard arguments.count == 2, arguments[0] == "--limit",
              let value = Int(arguments[1]), value > 0
        else {
            if let first = arguments.first, first != "--limit" {
                throw ParseError.invalidOption(first)
            }
            throw ParseError.invalidLimit
        }
        return min(value, LocalControlRouter.maxResults)
    }
}

enum VeloraCLI {
    static let usage = """
        Usage: velora <command> [options]

          status                  Show app, engine, and access status
          recent [--limit N]      Show recent dictations
          search QUERY [--limit N]
                                  Search local dictation history
          stats                   Show local voice intelligence
          transcribe FILE [--mode NAME]
                                  Transcribe an audio file locally
          listen [--mode NAME]    Request one visibly approved dictation
          action TEXT [--execute] [--allow-send]
                                  Plan a spoken command. --execute runs it;
                                  --allow-send also permits plans that message
                                  someone (implies --execute)
          modes list [--limit N]   List saved mode names
          modes validate FILE     Validate a recipe without installing it
          modes init [NAME] [--recipe ID]
                                  Print a recipe scaffold to stdout
          vocabulary list [--limit N]
          vocabulary add TEXT [--heard-as TEXT]
          vocabulary remove ID --yes
          meetings list [--limit N]
          meetings search QUERY [--limit N]
          meetings show ID [--limit N]
          meetings export ID [--format markdown|text|srt|vtt]
          format TEXT [--mode NAME]
          format --file FILE [--mode NAME]
                                  Reformat supplied text without saving or pasting
          model status            Show configured models and engine readiness
          paste-last --copy       Copy the last dictation explicitly
          paste-last --paste --target BUNDLE_ID
                                  Paste only into the specified app if focused
          mcp                     Run the MCP stdio server

        Add --json to any command except mcp for JSON output.
        """

    static func shouldRun(arguments: [String]) -> Bool {
        guard let executable = arguments.first else { return false }
        if arguments.contains("--cli") { return true }
        let url = URL(fileURLWithPath: executable).standardizedFileURL
        return url.lastPathComponent == "velora"
            && url.deletingLastPathComponent().lastPathComponent == "bin"
            && url.deletingLastPathComponent().deletingLastPathComponent()
                .lastPathComponent == "Resources"
    }

    static func run(arguments: [String] = CommandLine.arguments) -> Int32 {
        let raw = Array(arguments.dropFirst())
        if raw == ["--help"] || raw == ["-h"] {
            writeOutput(usage + "\n")
            return 0
        }
        let invocation: CLIInvocation
        do {
            invocation = try CLIInvocation.parse(raw)
        } catch {
            writeError("\(error.localizedDescription)\n\n\(usage)\n")
            return 2
        }

        if invocation.command == .mcp {
            MCPStdioServer.run()
            return 0
        }

        let command: String
        var payload: [String: Any] = [:]
        switch invocation.command {
        case .status: command = "status"
        case .recent(let limit):
            command = "recent"; payload["limit"] = limit
        case .search(let query, let limit):
            command = "search"; payload["query"] = query; payload["limit"] = limit
        case .stats: command = "stats"
        case .transcribe(let path, let mode):
            command = "transcribe"
            payload["path"] = absolutePath(path)
            if let mode { payload["mode"] = mode }
        case .listen(let mode):
            command = "listen"
            if let mode { payload["mode"] = mode }
        case .action(let text, let execute, let allowSend):
            command = "action"
            payload["text"] = text
            payload["execute"] = execute
            payload["allow_send"] = allowSend
        case .axProbe:
            command = "ax_probe"
        case .workflow(let name, let values):
            command = name
            for (key, value) in values {
                if key == "limit", let count = Int(value) { payload[key] = count }
                else if key == "confirm" { payload[key] = value == "true" }
                else { payload[key] = value }
            }
        case .mcp: return 0
        }

        do {
            if let file = payload.removeValue(forKey: "recipe_file") as? String {
                payload["document"] = try readTextFile(file, maximumBytes: ModeRecipeDocument.maximumBytes)
            }
            if let file = payload.removeValue(forKey: "text_file") as? String {
                payload["text"] = try readTextFile(file, maximumBytes: 240_000)
            }
            let result = try LocalControlClient.send(
                command: command, arguments: payload,
                timeoutSeconds: ["listen", "transcribe", "action", "format_text"].contains(command) ? 360 : 60)
            if invocation.json {
                writeOutput(json(result, pretty: true) + "\n")
            } else {
                writeOutput(human(result, command: command) + "\n")
            }
            return 0
        } catch {
            if invocation.json {
                writeOutput(json([
                    "ok": false,
                    "error": ["message": error.localizedDescription],
                ], pretty: true) + "\n")
            } else {
                writeError("velora: \(error.localizedDescription)\n")
            }
            return 1
        }
    }

    static func json(_ object: Any, pretty: Bool) -> String {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(
                withJSONObject: object,
                options: pretty ? [.prettyPrinted, .sortedKeys] : [.sortedKeys])
        else { return "{}" }
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    private static func human(_ result: [String: Any], command: String) -> String {
        if command == "status" {
            let app = (result["app_running"] as? Bool) == true ? "running" : "unavailable"
            let engine = (result["engine_ready"] as? Bool) == true ? "ready" : "starting"
            let access = (result["access_enabled"] as? Bool) == true ? "enabled" : "disabled"
            let restart = (result["safe_to_restart"] as? Bool) == true
                ? "yes"
                : "no — \(result["restart_block_reason"] as? String ?? "busy")"
            return "Velora app: \(app)\nSpeech engine: \(engine)"
                + "\nLocal agent access: \(access)\nSafe to restart: \(restart)"
        }
        if command == "recent" || command == "search" {
            guard let records = result["records"] as? [[String: Any]], !records.isEmpty else {
                return "No dictations found."
            }
            return records.map { record in
                let date = record["timestamp"] as? String ?? ""
                let app = record["app_name"] as? String ?? "Unknown app"
                let mode = record["mode"] as? String
                let header = [date, app, mode].compactMap { $0 }.joined(separator: " · ")
                return header + "\n" + (record["text"] as? String ?? "")
            }.joined(separator: "\n\n")
        }
        if ["listen", "transcribe", "format_text", "meetings_export"].contains(command) {
            return result["text"] as? String ?? ""
        }
        if command == "modes_init" { return result["document"] as? String ?? "" }
        return json(result, pretty: true)
    }

    private static func readTextFile(_ path: String, maximumBytes: Int) throws -> String {
        let file = URL(fileURLWithPath: absolutePath(path))
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: maximumBytes + 1) ?? Data()
        guard data.count <= maximumBytes, let text = String(data: data, encoding: .utf8) else {
            throw ControlFailure(code: "invalid_file", message: "Supply a UTF-8 text file no larger than \(maximumBytes) bytes")
        }
        return text
    }

    private static func absolutePath(_ path: String) -> String {
        if path.hasPrefix("/") {
            return URL(fileURLWithPath: path).standardizedFileURL.path
        }
        let base = URL(
            fileURLWithPath: FileManager.default.currentDirectoryPath,
            isDirectory: true)
        return URL(fileURLWithPath: path, relativeTo: base).standardizedFileURL.path
    }

    static func writeOutput(_ string: String) {
        FileHandle.standardOutput.write(Data(string.utf8))
    }

    static func writeError(_ string: String) {
        FileHandle.standardError.write(Data(string.utf8))
    }
}
