import Foundation
import TurboFieldfare

struct ToolRegistry {
    static let definitions: [GFTokenizer.FunctionDefinition] = [
        GFTokenizer.FunctionDefinition(
            name: "read_url",
            description: "Fetches the content of a URL and converts the HTML into readable Markdown text.",
            parameters: .object([
                "type": .string("object"),
                "properties": .object([
                    "url": .object(["type": .string("string")])
                ]),
                "required": .array([.string("url")])
            ])
        ),
        GFTokenizer.FunctionDefinition(
            name: "invoke_subagent",
            description: "Spawns a subagent to complete a complex sub-task. Use this to delegate long research or refactoring tasks.",
            parameters: .object([
                "type": .string("object"),
                "properties": .object([
                    "prompt": .object(["type": .string("string")])
                ]),
                "required": .array([.string("prompt")])
            ])
        ),
        GFTokenizer.FunctionDefinition(
            name: "code_nav_init",
            description: "Initialize tree-sitter AST index",
            parameters: .object([
                "type": .string("object"),
                "properties": .object([
                    "reset": .object(["type": .string("string")])
                ])
            ])
        ),
        GFTokenizer.FunctionDefinition(
            name: "code_symbols",
            description: "List top-level symbols in a file or directory",
            parameters: .object([
                "type": .string("object"),
                "properties": .object([
                    "path": .object(["type": .string("string")])
                ]),
                "required": .array([.string("path")])
            ])
        ),
        GFTokenizer.FunctionDefinition(
            name: "code_query",
            description: "Query AST using S-expressions",
            parameters: .object([
                "type": .string("object"),
                "properties": .object([
                    "query": .object(["type": .string("string")])
                ]),
                "required": .array([.string("query")])
            ])
        ),
        GFTokenizer.FunctionDefinition(
            name: "read_file",
            description: "Reads the contents of a file",
            parameters: .object([
                "type": .string("object"),
                "properties": .object([
                    "path": .object(["type": .string("string")])
                ]),
                "required": .array([.string("path")])
            ])
        ),
        GFTokenizer.FunctionDefinition(
            name: "write_file",
            description: "Writes content to a file",
            parameters: .object([
                "type": .string("object"),
                "properties": .object([
                    "path": .object(["type": .string("string")]),
                    "content": .object(["type": .string("string")])
                ]),
                "required": .array([.string("path"), .string("content")])
            ])
        ),
        GFTokenizer.FunctionDefinition(
            name: "edit_file",
            description: "Replaces a specific target string with a replacement string in a file.",
            parameters: .object([
                "type": .string("object"),
                "properties": .object([
                    "path": .object(["type": .string("string")]),
                    "target": .object(["type": .string("string")]),
                    "replacement": .object(["type": .string("string")])
                ]),
                "required": .array([.string("path"), .string("target"), .string("replacement")])
            ])
        ),
        GFTokenizer.FunctionDefinition(
            name: "execute_bash",
            description: "Executes a shell command natively",
            parameters: .object([
                "type": .string("object"),
                "properties": .object([
                    "command": .object(["type": .string("string")])
                ]),
                "required": .array([.string("command")])
            ])
        )
    ]

    static func execute(call: ParsedToolCall, runtime: AgentRuntime) async -> String {
        switch call.name {
        case "invoke_subagent":
            return await executeInvokeSubagent(call: call, runtime: runtime)
        case "code_nav_init", "code_symbols", "code_query":
            return executeMCP(call: call)
        case "read_url":
            return await executeReadURL(call: call)
        case "read_file":
            return executeReadFile(call: call)
        case "write_file":
            return executeWriteFile(call: call)
        case "edit_file":
            return executeEditFile(call: call)
        case "execute_bash":
            return executeBash(call: call)
        default:
            return "Error: unknown tool"
        }
    }

    private static func executeInvokeSubagent(call: ParsedToolCall, runtime: AgentRuntime) async -> String {
        var promptStr = ""
        if case .object(let map) = call.arguments, case .string(let p) = map["prompt"] { promptStr = p }

        printColor("\n--- [Subagent Started] ---\n", color: "blue")
        let subSession = AgentSession(runtime: runtime)
        subSession.messages[0] = GFTokenizer.Message(role: .system, content: runtime.config.systemPrompt + "\n\nYou are a SUBAGENT working on a delegated task. Return the final result clearly.", toolCalls: [], toolCallID: nil, name: nil)
        subSession.messages.append(GFTokenizer.Message(role: .user, content: promptStr, toolCalls: [], toolCallID: nil, name: nil))

        var turnActive = true
        while turnActive {
            do {
                let (content, subCalls) = try await runtime.generate(messages: subSession.messages)
                var hCalls: [GFTokenizer.HistoricalToolCall] = []
                for c in subCalls { hCalls.append(GFTokenizer.HistoricalToolCall(id: c.id, name: c.name, arguments: c.arguments)) }
                subSession.messages.append(GFTokenizer.Message(role: .assistant, content: content.isEmpty ? nil : content, toolCalls: hCalls, toolCallID: nil, name: nil))
                if !subCalls.isEmpty {
                    for c in subCalls {
                        var argString = ""
                        if case .object(let map) = c.arguments {
                            if let c = map["command"], case .string(let s) = c { argString = s.replacingOccurrences(of: "\n", with: " ") }
                            else if let p = map["path"], case .string(let s) = p { argString = s }
                            else if let q = map["query"], case .string(let s) = q { argString = s }
                            else if let pr = map["prompt"], case .string(let s) = pr { argString = s }
                            else if let url = map["url"], case .string(let s) = url { argString = s }
                            else { argString = map.keys.joined(separator: ", ") }
                            if argString.count > 60 { argString = String(argString.prefix(60)) + "..." }
                        }
                        printColor("\n● \(c.name)(\(argString))\n", color: "green")
                        let rStr = await ToolRegistry.execute(call: c, runtime: runtime)
                        printColor("   \(rStr.prefix(200))\(rStr.count > 200 ? "..." : "")\n", color: "yellow")
                        subSession.messages.append(GFTokenizer.Message(role: .tool, content: rStr, toolCalls: [], toolCallID: c.id, name: c.name))
                    }
                } else {
                    turnActive = false
                }
            } catch {
                return "Subagent Error: \(error)"
            }
        }
        printColor("\n--- [Subagent Finished] ---\n", color: "blue")
        return subSession.messages.last?.content ?? "No output from subagent."
    }

    private static func executeMCP(call: ParsedToolCall) -> String {
        guard let mcp = MCPClient.shared else { return "Error: MCP Client not initialized" }
        var args: [String: Any] = [:]
        if case .object(let map) = call.arguments {
            for (k, v) in map {
                if case .string(let s) = v { args[k] = s }
            }
        }
        return mcp.callTool(name: call.name, args: args)
    }

    private static func executeReadURL(call: ParsedToolCall) async -> String {
        if case .object(let argsMap) = call.arguments, case .string(let urlStr) = argsMap["url"], let url = URL(string: urlStr) {
            do {
                let (data, response) = try await URLSession.shared.data(from: url)
                guard let httpResponse = response as? HTTPURLResponse, (200...299).contains(httpResponse.statusCode) else {
                    return "Error: Bad HTTP response"
                }
                if let html = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .ascii) {
                    var text = html
                    text = text.replacingOccurrences(of: "(?is)<script.*?>.*?</script>", with: "", options: [.regularExpression])
                    text = text.replacingOccurrences(of: "(?is)<style.*?>.*?</style>", with: "", options: [.regularExpression])
                    text = text.replacingOccurrences(of: "(?is)<svg.*?>.*?</svg>", with: "", options: [.regularExpression])
                    text = text.replacingOccurrences(of: "(?i)<br\\s*/?>", with: "\n", options: [.regularExpression])
                    text = text.replacingOccurrences(of: "(?i)</p>", with: "\n\n", options: [.regularExpression])
                    text = text.replacingOccurrences(of: "(?i)</div>", with: "\n", options: [.regularExpression])
                    text = text.replacingOccurrences(of: "(?i)</h1>", with: "\n\n", options: [.regularExpression])
                    text = text.replacingOccurrences(of: "(?i)</h2>", with: "\n\n", options: [.regularExpression])
                    text = text.replacingOccurrences(of: "(?i)</li>", with: "\n", options: [.regularExpression])
                    text = text.replacingOccurrences(of: "(?i)<li>", with: "- ", options: [.regularExpression])
                    text = text.replacingOccurrences(of: "(?i)<a[^>]+href=\"([^\"]+)\"[^>]*>(.*?)</a>", with: "[$2]($1)", options: [.regularExpression])
                    text = text.replacingOccurrences(of: "<[^>]+>", with: "", options: [.regularExpression])
                    text = text.replacingOccurrences(of: "&nbsp;", with: " ")
                    text = text.replacingOccurrences(of: "&amp;", with: "&")
                    text = text.replacingOccurrences(of: "&lt;", with: "<")
                    text = text.replacingOccurrences(of: "&gt;", with: ">")
                    text = text.replacingOccurrences(of: "&quot;", with: "\"")
                    text = text.replacingOccurrences(of: "&#39;", with: "'")
                    text = text.replacingOccurrences(of: " {2,}", with: " ", options: [.regularExpression])
                    text = text.replacingOccurrences(of: "\\n{3,}", with: "\n\n", options: [.regularExpression])
                    return text.trimmingCharacters(in: .whitespacesAndNewlines)
                }
                return "Error: Unable to decode text"
            } catch {
                return "Error fetching URL: \(error)"
            }
        } else {
            return "Error: invalid URL"
        }
    }

    private static func executeReadFile(call: ParsedToolCall) -> String {
        if case .object(let argsMap) = call.arguments, case .string(let path) = argsMap["path"] {
            do {
                let content = try String(contentsOfFile: path, encoding: .utf8)
                return content
            } catch {
                return "Error reading file: \(error)"
            }
        } else {
            return "Error: invalid arguments"
        }
    }

    private static func executeWriteFile(call: ParsedToolCall) -> String {
        if case .object(let argsMap) = call.arguments, case .string(let path) = argsMap["path"], case .string(let content) = argsMap["content"] {
            do {
                try content.write(toFile: path, atomically: true, encoding: .utf8)
                return "Successfully wrote to \(path)"
            } catch {
                return "Error writing file: \(error)"
            }
        } else {
            return "Error: invalid arguments"
        }
    }

    private static func executeEditFile(call: ParsedToolCall) -> String {
        if case .object(let argsMap) = call.arguments, case .string(let path) = argsMap["path"], case .string(let target) = argsMap["target"], case .string(let replacement) = argsMap["replacement"] {
            do {
                let content = try String(contentsOfFile: path, encoding: .utf8)
                guard content.contains(target) else {
                    return "Error: target string not found in file"
                }
                let updated = content.replacingOccurrences(of: target, with: replacement)
                try updated.write(toFile: path, atomically: true, encoding: .utf8)
                return "Successfully updated \(path)"
            } catch {
                return "Error editing file: \(error)"
            }
        } else {
            return "Error: invalid arguments. Received: \(call.arguments)"
        }
    }

    private static func executeBash(call: ParsedToolCall) -> String {
        if case .object(let argsMap) = call.arguments, case .string(let cmd) = argsMap["command"] {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/bash")
            process.arguments = ["-c", cmd]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            do {
                try process.run()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                var outputStr = String(data: data, encoding: .utf8) ?? ""
                let maxLength = 8192
                if outputStr.count > maxLength {
                    outputStr = String(outputStr.prefix(maxLength)) + "\n... (output truncated: too large for context window. please use grep, head, or tail to narrow it down)"
                }
                return outputStr
            } catch {
                return "Error: \(error)"
            }
        } else {
            return "Error: invalid arguments"
        }
    }
}
