import Foundation

enum CLICommand: Equatable {
    case status
    case recent(limit: Int)
    case search(query: String, limit: Int)
    case stats
    case transcribe(path: String, mode: String?)
    case listen(mode: String?)
    case mcp
}

struct CLIInvocation: Equatable {
    let command: CLICommand
    let json: Bool

    enum ParseError: LocalizedError {
        case missingCommand
        case unknownCommand(String)
        case missingQuery
        case missingPath
        case missingOptionValue(String)
        case invalidOption(String)
        case invalidLimit

        var errorDescription: String? {
            switch self {
            case .missingCommand: return "Missing command"
            case .unknownCommand(let value): return "Unknown command: \(value)"
            case .missingQuery: return "search requires a query"
            case .missingPath: return "transcribe requires an audio file path"
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
        default:
            throw ParseError.unknownCommand(name)
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
        case .mcp: return 0
        }

        do {
            let result = try LocalControlClient.send(
                command: command, arguments: payload,
                timeoutSeconds: command == "listen" || command == "transcribe" ? 360 : 30)
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
            return "Velora app: \(app)\nSpeech engine: \(engine)\nLocal agent access: \(access)"
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
        if command == "listen" || command == "transcribe" {
            return result["text"] as? String ?? ""
        }
        return json(result, pretty: true)
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
