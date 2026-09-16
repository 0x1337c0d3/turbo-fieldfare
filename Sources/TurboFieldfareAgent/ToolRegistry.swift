import Foundation
import TurboFieldfare
import TurboFieldfareServerCore

struct ToolRegistry {
    nonisolated(unsafe) static var definitions: [GFTokenizer.FunctionDefinition] = baseDefinitions
    nonisolated(unsafe) static var mcpTools: Set<String> = []
    static let baseDefinitions: [GFTokenizer.FunctionDefinition] = [
        GFTokenizer.FunctionDefinition(
            name: "update_scratchpad",
            description: "Updates the agent's scratchpad with notes, plans, and learnings. This memory is permanent and helps you remember your overarching goals and what you have tried across long debugging sessions.",
            parameters: .object([
                "type": .string("object"),
                "properties": .object([
                    "notes": .object(["type": .string("string")])
                ]),
                "required": .array([.string("notes")])
            ])
        ),
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
        )
    ]

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

    static func reloadMCPTools() async {
        var newDefs = baseDefinitions
        var newMcpTools = Set<String>()
        if let client = MCPClient.shared {
            let tools = adaptedMCPTools(await client.listAllTools())
            newDefs.append(contentsOf: tools)
            newMcpTools = Set(tools.map { $0.name })
        }
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
        case "update_scratchpad":
            guard let notes = call.stringArgument("notes") else { return "Error: invalid arguments" }
            if let store = context.scratchpadStore {
                store.notes = notes
                return "Scratchpad updated successfully."
            }
            return "Error: Scratchpad updates are not supported in this context."
        default:
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
}
