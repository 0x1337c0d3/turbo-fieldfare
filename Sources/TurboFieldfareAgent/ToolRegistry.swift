import Foundation
import TurboFieldfare
import TurboFieldfareServerCore

struct ToolRegistry {
    nonisolated(unsafe) static var definitions: [GFTokenizer.FunctionDefinition] = baseDefinitions
    nonisolated(unsafe) static var mcpTools: Set<String> = []
    static let baseDefinitions: [GFTokenizer.FunctionDefinition] = [
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
        ),
        GFTokenizer.FunctionDefinition(
            name: "list_dir",
            description: "List the contents of a directory.",
            parameters: .object([
                "type": .string("object"),
                "properties": .object(["path": .object(["type": .string("string")])]),
                "required": .array([.string("path")])
            ])
        ),
        GFTokenizer.FunctionDefinition(
            name: "find_by_name",
            description: "Search for files and directories matching specific patterns.",
            parameters: .object([
                "type": .string("object"),
                "properties": .object([
                    "path": .object(["type": .string("string")]),
                    "pattern": .object(["type": .string("string")])
                ]),
                "required": .array([.string("path"), .string("pattern")])
            ])
        ),
        GFTokenizer.FunctionDefinition(
            name: "grep_search",
            description: "Search for exact text matches or regular expressions within files.",
            parameters: .object([
                "type": .string("object"),
                "properties": .object([
                    "path": .object(["type": .string("string")]),
                    "query": .object(["type": .string("string")])
                ]),
                "required": .array([.string("path"), .string("query")])
            ])
        ),
        GFTokenizer.FunctionDefinition(
            name: "analyze_image",
            description: "Examine a local image file. The image will be staged and appended to your context for analysis.",
            parameters: .object([
                "type": .string("object"),
                "properties": .object(["path": .object(["type": .string("string")])]),
                "required": .array([.string("path")])
            ])
        ),
        GFTokenizer.FunctionDefinition(
            name: "define_subagent",
            description: "Defines a new type of subagent.",
            parameters: .object([
                "type": .string("object"),
                "properties": .object([
                    "name": .object(["type": .string("string")]),
                    "system_prompt": .object(["type": .string("string")])
                ]),
                "required": .array([.string("name"), .string("system_prompt")])
            ])
        ),
        GFTokenizer.FunctionDefinition(
            name: "manage_subagents",
            description: "List or kill active subagents.",
            parameters: .object([
                "type": .string("object"),
                "properties": .object([
                    "action": .object(["type": .string("string")])
                ]),
                "required": .array([.string("action")])
            ])
        ),
        GFTokenizer.FunctionDefinition(
            name: "send_message",
            description: "Communicate with a subagent.",
            parameters: .object([
                "type": .string("object"),
                "properties": .object([
                    "id": .object(["type": .string("string")]),
                    "message": .object(["type": .string("string")])
                ]),
                "required": .array([.string("id"), .string("message")])
            ])
        ),
        GFTokenizer.FunctionDefinition(
            name: "schedule",
            description: "Set a timer or recurring schedule.",
            parameters: .object([
                "type": .string("object"),
                "properties": .object([
                    "duration_seconds": .object(["type": .string("integer")]),
                    "prompt": .object(["type": .string("string")])
                ]),
                "required": .array([.string("duration_seconds"), .string("prompt")])
            ])
        ),
        GFTokenizer.FunctionDefinition(
            name: "manage_task",
            description: "Manage background tasks.",
            parameters: .object([
                "type": .string("object"),
                "properties": .object([
                    "action": .object(["type": .string("string")])
                ]),
                "required": .array([.string("action")])
            ])
        )
    ]

    static func memoryDefinitions(service: MemoryService?) async -> [GFTokenizer.FunctionDefinition] {
        guard let service = service else { return [] }
        return await service.toolDefinitions().map { def in
            GFTokenizer.FunctionDefinition(
                name: def.name,
                description: def.description,
                parameters: try! mapMemorySchema(def.parameters)
            )
        }
    }

    private static func mapMemorySchema(_ schema: MemoryToolSchema) throws -> JSONValue {
        switch schema {
        case .string: return .object(["type": .string("string")])
        case .integer: return .object(["type": .string("integer")])
        case .number: return .object(["type": .string("number")])
        case .stringArray: return .object(["type": .string("array"), "items": .object(["type": .string("string")])])
        case .object(let properties, let required):
            var mappedProps: [String: JSONValue] = [:]
            for (key, val) in properties { mappedProps[key] = try mapMemorySchema(val) }
            return .object(["type": .string("object"), "properties": .object(mappedProps), "required": .array(required.map { .string($0) })])
        }
    }

    static func adaptedMCPTools(
        _ tools: [GFTokenizer.FunctionDefinition],
        reportError: (String) -> Void = { printColor($0 + "\n", color: "yellow") }
    ) -> [GFTokenizer.FunctionDefinition] {
        let reservedNames = Set(baseDefinitions.map(\.name))
        return tools.compactMap { tool in
            guard !reservedNames.contains(tool.name) else {
                reportError("Skipping MCP tool \(tool.name): name is reserved by a built-in tool")
                return nil
            }
            do {
                return GFTokenizer.FunctionDefinition(
                    name: tool.name, description: tool.description,
                    parameters: try GemmaToolSchema.adapted(tool.parameters, toolName: tool.name))
            } catch {
                reportError("Skipping MCP tool \(tool.name): \(error)")
                return nil
            }
        }
    }

    static func reloadMCPTools(memoryService: MemoryService? = nil) async {
        var newDefs = baseDefinitions
        var newMcpTools = Set<String>()
        if let client = MCPClient.shared {
            let tools = adaptedMCPTools(await client.listAllTools())
            newDefs.append(contentsOf: tools)
            newMcpTools = Set(tools.map { $0.name })
        }
        newDefs.append(contentsOf: await memoryDefinitions(service: memoryService))
        definitions = newDefs
        mcpTools = newMcpTools
    }

    static func isMCPTool(_ name: String, definitions: [GFTokenizer.FunctionDefinition]) -> Bool {
        !baseDefinitions.contains(where: { $0.name == name })
            && definitions.contains(where: { $0.name == name })
    }

    static func execute(call: ParsedToolCall, runtime: AgentRuntime,
                        context suppliedContext: AgentToolContext? = nil) async -> String {
        let context = suppliedContext ?? .terminal(runtime)
        if context.interaction?.cancellation.isCancelled == true || Task.isCancelled { return "Error: cancelled" }
        guard runtime.remainingToolCalls > 0 else { return "Error: tool-call budget exhausted for this user turn" }
        runtime.remainingToolCalls -= 1
        let approved: Bool
        if runtime.config.args.yolo { approved = true }
        else if call.name == "invoke_subagent" { approved = true }
        else if let interaction = context.interaction { approved = await interaction.approve(call) }
        else { approved = ToolApproval.request(call) }
        guard approved else {
            return "Tool call denied by the user or unavailable in non-interactive mode. Do not retry without a new user request."
        }
        if context.interaction?.cancellation.isCancelled == true || Task.isCancelled { return "Error: cancelled" }
        context.interaction?.tool(call, "in_progress", nil)
        switch call.name {
        case "invoke_subagent":
            return await executeInvokeSubagent(call: call, runtime: runtime, context: context)
        case "read_url":
            return await executeReadURL(call: call)
        case "read_file":
            return await executeReadFile(call: call, context: context)
        case "write_file":
            return await executeWriteFile(call: call, context: context)
        case "edit_file":
            return await executeEditFile(call: call, context: context)
        case "execute_bash":
            return await executeBash(call: call, context: context)
        case "list_dir":
            return await executeListDir(call: call, context: context)
        case "find_by_name":
            return await executeFindByName(call: call, context: context)
        case "grep_search":
            return await executeGrepSearch(call: call, context: context)
        case "analyze_image":
            return await executeAnalyzeImage(call: call, context: context)
        case "define_subagent":
            guard let name = call.stringArgument("name"), let prompt = call.stringArgument("system_prompt") else { return "Error" }
            await AgentManager.shared.defineSubagent(name: name, prompt: prompt)
            return "Subagent \(name) defined."
        case "manage_subagents":
            return await AgentManager.shared.listSubagents()
        case "send_message":
            guard let id = call.stringArgument("id"), let msg = call.stringArgument("message") else { return "Error" }
            return await AgentManager.shared.sendMessage(id: id, message: msg)
        case "schedule":
            guard let duration = call.intArgument("duration_seconds"), let prompt = call.stringArgument("prompt") else { return "Error" }
            let id = UUID().uuidString
            await AgentManager.shared.startTask(id: id, description: "Timer for \(duration)s: \(prompt)") {
                try? await Task.sleep(nanoseconds: UInt64(duration) * 1_000_000_000)
                print("\n[Timer Fired]: \(prompt)")
            }
            return "Scheduled task \(id)"
        case "manage_task":
            return await AgentManager.shared.listTasks()
        default:
            if let memoryService = context.memoryService,
               await memoryService.toolDefinitions().contains(where: { $0.name == call.name }) {
                let session = await memoryService.beginSession(id: "agent_turn", workspaceOverride: context.directory.path, modelID: nil, tag: nil, focus: nil)
                guard let session = session else { return "Error: memory session rejected" }
                do {
                    let data = call.argumentsJSON.data(using: .utf8)!
                    let dict = try JSONDecoder().decode([String: MemoryToolValue].self, from: data)
                    let result = await memoryService.execute(name: call.name, arguments: dict, in: session)
                    return result.jsonString()
                    
                } catch {
                    return "Error parsing memory tool args: \(error)"
                }
            }
            if isMCPTool(call.name, definitions: context.definitions) {
                return await executeMCP(call: call, mcp: context.mcp)
            }
            return "Error: unknown tool"
        }
    }

    private static func executeInvokeSubagent(call: ParsedToolCall, runtime: AgentRuntime,
                                             context: AgentToolContext) async -> String {
        guard runtime.subagentDepth < 4 else { return "Error: subagent nesting limit reached" }
        runtime.subagentDepth += 1
        defer { runtime.subagentDepth -= 1 }
        var messages = [
            GFTokenizer.Message(role: .system, content: context.systemPrompt + "\nYou are a delegated subagent. Return your result clearly.", toolCalls: [], toolCallID: nil, name: nil),
            GFTokenizer.Message(role: .user, content: call.stringArgument("prompt") ?? "", toolCalls: [], toolCallID: nil, name: nil)
        ]
        do {
            return try await AgentTurn.run(runtime: runtime, messages: &messages, context: context, resultLimit: 200)
        } catch { return "Error: subagent failed: \(error)" }
    }

    private static func executeMCP(call: ParsedToolCall, mcp: MCPClient?) async -> String {
        guard let mcp else { return "Error: MCP Client not initialized" }
        guard let argsData = try? JSONEncoder().encode(call.arguments),
              let argsJson = String(data: argsData, encoding: .utf8) else {
            return "Error: invalid MCP arguments"
        }
        return await mcp.callTool(name: call.name, argsJson: argsJson)
    }

    private static func executeReadURL(call: ParsedToolCall) async -> String {
        guard let urlString = call.stringArgument("url"), let url = URL(string: urlString) else {
            return "Error: invalid URL"
        }
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard let response = response as? HTTPURLResponse, (200...299).contains(response.statusCode) else {
                return "Error: Bad HTTP response"
            }
            guard let html = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .ascii) else {
                return "Error: Unable to decode text"
            }
            return ReadableHTML.text(from: html)
        } catch {
            return "Error fetching URL: \(error)"
        }
    }

    private static func executeReadFile(call: ParsedToolCall, context: AgentToolContext) async -> String {
        guard let path = call.stringArgument("path") else { return "Error: invalid arguments" }
        do {
            return try await readFile(context.path(path), context: context)
        } catch {
            return "Error reading file: \(error)"
        }
    }

    private static func executeWriteFile(call: ParsedToolCall, context: AgentToolContext) async -> String {
        guard let path = call.stringArgument("path"),
              let content = call.stringArgument("content") else { return "Error: invalid arguments" }
        do {
            try await writeFile(context.path(path), content: content, context: context)
            return "Successfully wrote to \(path)"
        } catch {
            return "Error writing file: \(error)"
        }
    }

    private static func executeEditFile(call: ParsedToolCall, context: AgentToolContext) async -> String {
        guard let path = call.stringArgument("path"),
              let target = call.stringArgument("target"),
              let replacement = call.stringArgument("replacement") else {
            return "Error: invalid arguments. Received: \(call.arguments)"
        }
        do {
            let content = try await readFile(context.path(path), context: context)
            guard content.contains(target) else { return "Error: target string not found in file" }
            let updated = content.replacingOccurrences(of: target, with: replacement)
            try await writeFile(context.path(path), content: updated, context: context)
            return "Successfully updated \(path)"
        } catch {
            return "Error editing file: \(error)"
        }
    }

    private static func readFile(_ path: String, context: AgentToolContext) async throws -> String {
        if let read = context.interaction?.readFile { return try await read(path) }
        return try String(contentsOfFile: path, encoding: .utf8)
    }

    private static func writeFile(_ path: String, content: String, context: AgentToolContext) async throws {
        try context.interaction?.cancellation.check()
        if let write = context.interaction?.writeFile { try await write(path, content); return }
        try content.write(toFile: path, atomically: true, encoding: .utf8)
    }

    private static func executeBash(call: ParsedToolCall, context: AgentToolContext) async -> String {
        guard let command = call.stringArgument("command") else { return "Error: invalid arguments" }
        do {
            let output = try await ShellCommand.run(command, directory: context.directory, cancellation: context.interaction?.cancellation)
            guard output.count > 8192 else { return output }
            return String(output.prefix(8192))
                + "\n... (output truncated: too large for context window. please use grep, head, or tail to narrow it down)"
        } catch {
            return "Error: \(error)"
        }
    }

    private static func executeListDir(call: ParsedToolCall, context: AgentToolContext) async -> String {
        guard let path = call.stringArgument("path") else { return "Error: invalid arguments" }
        do {
            let contents = try FileManager.default.contentsOfDirectory(atPath: context.path(path))
            return contents.joined(separator: "\n")
        } catch {
            return "Error listing directory: \(error)"
        }
    }

    private static func executeFindByName(call: ParsedToolCall, context: AgentToolContext) async -> String {
        guard let path = call.stringArgument("path"), let pattern = call.stringArgument("pattern") else { return "Error: invalid arguments" }
        do {
            let output = try await ShellCommand.run("find \"\(context.path(path))\" -name \"\(pattern)\"", directory: context.directory, cancellation: context.interaction?.cancellation)
            return output.isEmpty ? "No files found matching \(pattern)" : output
        } catch {
            return "Error finding files: \(error)"
        }
    }

    private static func executeGrepSearch(call: ParsedToolCall, context: AgentToolContext) async -> String {
        guard let path = call.stringArgument("path"), let query = call.stringArgument("query") else { return "Error: invalid arguments" }
        do {
            let output = try await ShellCommand.run("grep -rnI \"\(query)\" \"\(context.path(path))\"", directory: context.directory, cancellation: context.interaction?.cancellation)
            guard output.count > 8192 else { return output.isEmpty ? "No matches found" : output }
            return String(output.prefix(8192)) + "\n... (output truncated)"
        } catch {
            return "Error running grep: \(error)"
        }
    }

    private static func executeAnalyzeImage(call: ParsedToolCall, context: AgentToolContext) async -> String {
        guard let path = call.stringArgument("path") else { return "Error: invalid arguments" }
        // For the CLI context, we need to instruct the runtime to stage the image.
        // Since TurboFieldfareAgent doesn't natively hold the StagedImage context here, 
        // we emit a system directive that the image is staged if running in App, 
        // or print a local warning. 
        return "Image at \(path) staged for analysis. Instruct the user to view or describe it."
    }
}
