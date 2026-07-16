import Foundation

/// Minimal MCP 2025-06-18 stdio adapter. The transport is newline-delimited
/// JSON-RPC; stdout is reserved exclusively for protocol messages.
enum MCPStdioServer {
    static let protocolVersion = "2025-06-18"
    typealias Caller = (String, [String: Any]) -> Result<[String: Any], ControlFailure>

    static func run() {
        while let line = readLine(strippingNewline: true) {
            guard let data = line.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data),
                  let message = object as? [String: Any]
            else {
                emit(error(id: NSNull(), code: -32700, message: "Parse error"))
                continue
            }
            if let response = process(message, caller: liveCaller) { emit(response) }
        }
    }

    static func process(_ message: [String: Any], caller: Caller) -> [String: Any]? {
        let hasID = message.keys.contains("id")
        let id = message["id"] ?? NSNull()
        guard message["jsonrpc"] as? String == "2.0",
              let method = message["method"] as? String else {
            return hasID ? error(id: id, code: -32600, message: "Invalid Request") : nil
        }
        let params = message["params"] as? [String: Any] ?? [:]

        switch method {
        case "initialize":
            guard hasID else { return nil }
            return success(id: id, result: [
                "protocolVersion": protocolVersion,
                "capabilities": ["tools": ["listChanged": false]],
                "serverInfo": [
                    "name": "Velora",
                    "version": Bundle.main.object(
                        forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev",
                ],
            ])
        case "notifications/initialized":
            return nil
        case "ping":
            return hasID ? success(id: id, result: [:]) : nil
        case "tools/list":
            guard hasID else { return nil }
            return success(id: id, result: ["tools": tools])
        case "tools/call":
            guard hasID else { return nil }
            guard let name = params["name"] as? String else {
                return error(id: id, code: -32602, message: "Invalid tool arguments")
            }
            let arguments: [String: Any]
            if params["arguments"] == nil {
                arguments = [:]
            } else if let supplied = params["arguments"] as? [String: Any] {
                arguments = supplied
            } else {
                return error(id: id, code: -32602, message: "Invalid tool arguments")
            }
            guard let command = toolCommand(name) else {
                return toolResult(
                    id: id, payload: ["error": "Unknown tool: \(name)"], isError: true)
            }
            switch caller(command, arguments) {
            case .success(let payload):
                return toolResult(id: id, payload: payload, isError: false)
            case .failure(let failure):
                return toolResult(
                    id: id,
                    payload: ["error": failure.message, "code": failure.code],
                    isError: true)
            }
        default:
            return hasID ? error(id: id, code: -32601, message: "Method not found") : nil
        }
    }

    private static let liveCaller: Caller = { command, arguments in
        do {
            return .success(try LocalControlClient.send(
                command: command, arguments: arguments,
                timeoutSeconds: command == "listen" || command == "transcribe" ? 360 : 30))
        } catch let ControlClientError.remote(failure) {
            return .failure(failure)
        } catch {
            return .failure(ControlFailure(
                code: "app_unavailable", message: error.localizedDescription))
        }
    }

    private static func toolCommand(_ name: String) -> String? {
        switch name {
        case "velora_status": return "status"
        case "recent_dictations": return "recent"
        case "search_dictations": return "search"
        case "voice_stats": return "stats"
        case "transcribe_audio_file": return "transcribe"
        case "request_voice_input": return "listen"
        default: return nil
        }
    }

    static let tools: [[String: Any]] = [
        [
            "name": "velora_status",
            "description": "Check whether Velora, its speech engine, and local agent access are ready.",
            "inputSchema": ["type": "object", "properties": [:]],
        ],
        [
            "name": "recent_dictations",
            "description": "Read recent dictation text from Velora's local history.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "limit": ["type": "integer", "minimum": 1, "maximum": 100],
                ],
            ],
        ],
        [
            "name": "search_dictations",
            "description": "Search Velora's local dictation history for an exact text fragment.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "query": ["type": "string", "minLength": 1, "maxLength": 500],
                    "limit": ["type": "integer", "minimum": 1, "maximum": 100],
                ],
                "required": ["query"],
            ],
        ],
        [
            "name": "voice_stats",
            "description": "Read aggregate, local-only Velora usage and accuracy statistics.",
            "inputSchema": ["type": "object", "properties": [:]],
        ],
        [
            "name": "transcribe_audio_file",
            "description": "Transcribe a local audio file with Velora. Local agent access must be enabled.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "path": [
                        "type": "string",
                        "description": "Absolute path to a local audio file.",
                    ],
                    "mode": [
                        "type": "string", "minLength": 1, "maxLength": 128,
                        "description": "Optional built-in or custom Velora formatting mode.",
                    ],
                ],
                "required": ["path"],
            ],
        ],
        [
            "name": "request_voice_input",
            "description": "Ask the user for one voice response. Velora always shows an Allow Once dialog, visible recording HUD, and sounds; denial is returned as an error.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "mode": [
                        "type": "string", "minLength": 1, "maxLength": 128,
                        "description": "Optional built-in or custom Velora formatting mode.",
                    ],
                ],
            ],
        ],
    ]

    private static func toolResult(
        id: Any, payload: [String: Any], isError: Bool
    ) -> [String: Any] {
        success(id: id, result: [
            "content": [["type": "text", "text": VeloraCLI.json(payload, pretty: false)]],
            "structuredContent": payload,
            "isError": isError,
        ])
    }

    private static func success(id: Any, result: [String: Any]) -> [String: Any] {
        ["jsonrpc": "2.0", "id": id, "result": result]
    }

    private static func error(id: Any, code: Int, message: String) -> [String: Any] {
        [
            "jsonrpc": "2.0",
            "id": id,
            "error": ["code": code, "message": message],
        ]
    }

    private static func emit(_ object: [String: Any]) {
        guard JSONSerialization.isValidJSONObject(object),
              var data = try? JSONSerialization.data(
                withJSONObject: object, options: [.sortedKeys])
        else { return }
        data.append(0x0A)
        FileHandle.standardOutput.write(data)
    }
}
