import Foundation
import AppKit
import TurboFieldfare

final class AgentSession {
    let runtime: AgentRuntime
    var messages: [GFTokenizer.Message]
    let memoryService: MemoryService

    init(runtime: AgentRuntime) {
        self.runtime = runtime
        let directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        let memoryConfig = MemoryConfiguration.fromEnvironment(ProcessInfo.processInfo.environment)
        self.memoryService = MemoryService(configuration: memoryConfig, log: { _ in })
        self.messages = [
            GFTokenizer.Message(role: .system, content: runtime.config.systemPrompt, toolCalls: [], toolCallID: nil, name: nil)
        ]
        let service = self.memoryService
        Task { [service] in await service.warmUp() }
    }

    private func handleShellCommand(userInput: String) {
        let cmdStr = String(userInput.dropFirst()).trimmingCharacters(in: .whitespaces)
        printColor("\n● Shell: \(cmdStr)\n", color: "green")
        var outputStr: String
        do {
            outputStr = try ShellCommand.run(cmdStr)
        } catch {
            printColor("Error running shell command: \(error)\n", color: "yellow")
            return
        }
        if outputStr.isEmpty { outputStr = "(No output)" }

        let displayRes = outputStr.count > 2000 ? String(outputStr.prefix(2000)) + "... (truncated)" : outputStr
        printColor("   \(displayRes)\n", color: "gray")

        let contextStr = "[User Executed Shell Command]: \(cmdStr)\n[Output]:\n\(displayRes)"
        messages.append(GFTokenizer.Message(role: .user, content: contextStr, toolCalls: [], toolCallID: nil, name: nil))
    }

    private func processSlashCommand(userInput: String) -> String? {
        guard userInput.hasPrefix("/") else { return userInput }
        
        let parts = userInput.split(separator: " ", maxSplits: 1)
        guard let command = parts.first else { return userInput }
        
        let cmdName = String(command.dropFirst())
        let args = parts.count > 1 ? String(parts[1]) : ""

        let fm = FileManager.default
        let homeDir = fm.homeDirectoryForCurrentUser.path
        let localDir = fm.currentDirectoryPath

        let skills = SkillLibrary.discover(roots: [
            URL(fileURLWithPath: homeDir).appendingPathComponent(".agents/skills"),
            URL(fileURLWithPath: localDir).appendingPathComponent(".agents/skills")
        ])
        if cmdName.isEmpty || cmdName == "skills" {
            printColor("\n[Available Skills]:\n", color: "blue")
            if skills.isEmpty {
                printColor("  (No skills found in ~/.agents/skills/ or ./.agents/skills/)\n", color: "gray")
            } else {
                for skill in skills.keys.sorted() {
                    printColor("  /\(skill)\n", color: "green")
                }
            }
            return nil
        }

        let loadedSkillPath = skills[cmdName]?.path
        let loadedSkillContent = loadedSkillPath.flatMap { try? String(contentsOfFile: $0, encoding: .utf8) }

        if let skillContent = loadedSkillContent, let skillPath = loadedSkillPath {
            printColor("[Loaded skill /\(cmdName) from \(skillPath)]\n", color: "blue")
            return "[Skill: \(cmdName), source: \(skillPath)]\n\(skillContent)\n\nUser Request:\n\(args)"
        } else {
            printColor("Warning: Skill '/\(cmdName)' not found in ~/.agents/skills/ or ./.agents/skills/\n", color: "yellow")
            return nil
        }
    }

    private func printHelp() {
        printColor("""

        [Agent Help]
          Enter a message to ask the agent to work. Enter submits the prompt.
          Shift+Enter inserts a newline (Ctrl+J also works).
          Ctrl+A/Ctrl+E move to the start/end of the current line.
          Ctrl+O expands/collapses tool responses in place.
          Page Up/Page Down browse the retained transcript at the prompt.
          Ctrl+C clears the prompt; press again within 3 seconds to exit.
          Up/Down browse history until you edit the prompt, then move between lines.
          Shift+Enter requires a terminal that reports modified Enter keys.

        Commands
          ?                    Show this help (press Enter).
          /skills or /         List available slash skills.
          /<skill> [request]   Load a skill and send it with your request.
          @path                Attach a UTF-8 text file to your prompt.
          @"path with spaces"  Attach a file with spaces in its name.
          /prompt              Show the current system prompt.
          /copy                Copy the last assistant response as Markdown.
          /compact             Summarize and compress the conversation history.
          /clear or /new       Reset the context window to start fresh.
          /mcp                 Show configured MCP servers.
          /mcp reload          Reload MCP configuration and tool definitions.
          !<command>           Run a shell command; add its output to the conversation.
          /exit or /quit       Exit the agent.

        File references
          Example: Explain @Sources/TurboFieldfareAgent/Session.swift
          Paths are relative to the working directory; absolute and ~/ paths work.
          Up to 16 files, 256 KiB combined. Missing or invalid files stop submission.
          Separate references with whitespace; punctuation is part of the path.
          Emails stay literal; prefix an @ mention with a backslash to keep it literal.

        Skills
          Slash skills use <skill>.md or <skill>/SKILL.md in:
            ~/.agents/skills/  or  ./.agents/skills/
          If both contain the same name, the home-directory skill takes precedence.
          Example: review.md is invoked with /review Check my latest changes.
          Skill instructions are loaded only when invoked, not at startup.
          Reference documents are read only as needed for the selected skill.

        Built-in tools
          Ask for these in your message; the agent chooses when to call them.
          read_file            Read a file.
          write_file           Write a file.
          edit_file            Replace matching text in a file.
          execute_bash         Run a shell command.
          read_url             Fetch a URL and extract readable text.
          invoke_subagent      Delegate a task to a subagent.

        """, color: "gray")
        _ = processSlashCommand(userInput: "/skills")
    }

    func startRepl() async throws {
        runtime.statusLine.start(maxContext: runtime.config.args.maxContext)
        AgentTerminal.beginTranscript()
        AgentTerminal.onToggleMode = { [weak self] in
            guard let self = self else { return }
            switch self.runtime.routingMode {
            case .auto: self.runtime.routingMode = .forceCloud
            case .forceCloud: self.runtime.routingMode = .forceLocal
            case .forceLocal: self.runtime.routingMode = .auto
            }
            printColor("\n[Switched to \(self.runtime.routingMode.rawValue)]\n", color: "yellow")
        }
        
        defer {
            AgentTerminal.endTranscript()
            runtime.statusLine.stop()
        }
        printColor("\nType ? and press Enter for commands, skills, and built-in tools.\n", color: "gray")
        while let input = readInput() {
            if input == "/exit" || input == "/quit" { 
                break 
            }
            if await handleCommand(input) { continue }
            guard let request = processSlashCommand(userInput: input) else { continue }
            let prompt: String
            do {
                let directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
                prompt = request + (try FileReferences.context(in: input, directory: directory))
            } catch {
                printColor("\n[Error: \(error)]\n", color: "yellow")
                continue
            }
            runtime.remainingToolCalls = 64
            let priorMessageCount = messages.count
            messages.append(GFTokenizer.Message(role: .user, content: prompt, toolCalls: [], toolCallID: nil, name: nil))
            do {
                _ = try await completeTurn()
            } catch {
                printColor("\n[Error: \(error)]\n", color: "yellow")
                // Keep completed tool-call/result pairs if a later generation fails.
                if messages.count == priorMessageCount + 1 { messages.removeLast() }
            }
        }
    }

    func completeTurn(resultLimit: Int = 300) async throws -> String {
        let maxMessages = 30
        if messages.count > maxMessages {
            let keepCount = 20
            let startIdx = messages.count - keepCount
            var safeIdx = startIdx
            while safeIdx < messages.count {
                if messages[safeIdx].role == .user { break }
                safeIdx += 1
            }
            if safeIdx == messages.count { safeIdx = startIdx }
            let pinned = Array(messages.prefix(2))
            let rolling = Array(messages.suffix(from: safeIdx))
            messages = pinned + rolling
        }
        let context = AgentToolContext.terminal(runtime, memoryService: memoryService)
        return try await AgentTurn.run(runtime: runtime, messages: &messages,
                                       context: context, resultLimit: resultLimit)
    }

    private func readInput() -> String? {
        terminalPrint("")
        printSeparator()
        runtime.statusLine.preparePrompt()
        let prompt = "\u{01}\u{001B}[32m\u{02}> \u{01}\u{001B}[0m\u{02}"
        guard let input = ReadlineWrapper.read(prompt: prompt) else { return nil }
        AgentTerminal.recordPrompt(input)
        printSeparator()
        return input
    }

    private func handleCommand(_ input: String) async -> Bool {
        if input.trimmingCharacters(in: .whitespacesAndNewlines) == "?" {
            printHelp()
            return true
        }
        switch input {
        case "": break
        case "/prompt":
            printColor("\n[System Prompt]:\n\(runtime.config.systemPrompt)\n", color: "gray")
        case "/copy":
            copyLastResponse()
        case "/compact":
            await compactHistory()
        case "/mcp reload":
            await reloadMCP()
        case "/mcp":
            printMCPServers()
        case "/consolidate":
            await runConsolidation()
        case "/clear", "/new":
            await runConsolidation()
            messages = [messages[0]]
            printColor("\n[Context cleared. Starting fresh.]\n", color: "green")
        case _ where input.hasPrefix("!"):
            handleShellCommand(userInput: input)
        default: return false
        }
        return true
    }

    private func runConsolidation() async {
        let memoryService = self.memoryService
        printColor("\n[Running memory consolidation...]\n", color: "blue")
        do {
            let result = try await ConsolidationAgent.run(
                runtime: runtime, 
                memoryService: memoryService, 
                conversationHistory: messages
            )
            printColor("\n[Consolidation Complete]:\n\(result)\n", color: "green")
        } catch {
            printColor("\n[Consolidation Failed]: \(error)\n", color: "yellow")
        }
    }

    private func compactHistory() async {
        guard messages.count > 1 else {
            printColor("\n[History is already empty or only contains the system prompt.]\n", color: "yellow")
            return
        }
        
        printColor("\n[Compacting history...]\n", color: "blue")
        let originalMessages = messages
        
        messages.append(GFTokenizer.Message(role: .user, content: "Summarize the work done so far, noting any current objectives and dead-ends.", toolCalls: [], toolCallID: nil, name: nil))
        
        do {
            runtime.remainingToolCalls = 64
            let summary = try await completeTurn()
            messages = [
                originalMessages[0],
                GFTokenizer.Message(role: .user, content: "Summary of previous work:\n\(summary)", toolCalls: [], toolCallID: nil, name: nil)
            ]
            printColor("\n[History compacted successfully.]\n", color: "green")
        } catch {
            printColor("\n[Error compacting history: \(error)]\n", color: "red")
            messages = originalMessages
        }
    }

    private func copyLastResponse() {
        guard let response = messages.last(where: {
            $0.role == .assistant && $0.toolCalls.isEmpty && !($0.content ?? "").isEmpty
        })?.content else {
            printColor("\n[No assistant response to copy.]\n", color: "yellow")
            return
        }
        let clipboard = NSPasteboard.general
        clipboard.clearContents()
        if clipboard.setString(response, forType: .string) {
            printColor("\n[Last response copied as Markdown.]\n", color: "green")
        } else {
            printColor("\n[Could not copy the last response to the clipboard.]\n", color: "yellow")
        }
    }

    private func reloadMCP() async {
        MCPClient.shared = MCPClient()
        await ToolRegistry.reloadMCPTools()
        guard MCPClient.shared != nil else {
            printColor("\n[MCP Client]: Failed to reload configuration.\n", color: "red")
            return
        }
        printColor("\n[MCP Client]: Reloaded successfully.\n", color: "green")
    }

    private func printMCPServers() {
        guard let client = MCPClient.shared else {
            printColor("\n[MCP Client]: Not initialized or no configuration found.\n", color: "yellow")
            return
        }
        printColor("\n[MCP Servers]:\n", color: "blue")
        for server in client.servers {
            printColor("  - \(server.name) (\(server.connectionDetails))\n", color: "green")
        }
        if client.servers.isEmpty {
            printColor("  (No MCP servers configured or running)\n", color: "gray")
        }
    }
}
