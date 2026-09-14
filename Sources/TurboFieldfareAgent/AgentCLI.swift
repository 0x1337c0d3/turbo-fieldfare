import Foundation
import TurboFieldfare
import TurboFieldfareCLICore

// MARK: - Utilities
func printColor(_ text: String, color: String) {
    let colorCode: String
    switch color {
    case "green": colorCode = "\u{001B}[32m"
    case "yellow": colorCode = "\u{001B}[33m"
    case "blue": colorCode = "\u{001B}[34m"
    case "reset": colorCode = "\u{001B}[0m"
    case "gray": colorCode = "\u{001B}[90m"
    default: colorCode = ""
    }
    print("\(colorCode)\(text)\u{001B}[0m", terminator: "")
    fflush(stdout)
}

typealias ReadlineFunc = @convention(c) (UnsafePointer<CChar>?) -> UnsafeMutablePointer<CChar>?
typealias AddHistoryFunc = @convention(c) (UnsafePointer<CChar>?) -> Void
typealias HistoryIOFunc = @convention(c) (UnsafePointer<CChar>?) -> Int32

struct ReadlineWrapper {
    nonisolated(unsafe) static var readline: ReadlineFunc?
    nonisolated(unsafe) static var addHistory: AddHistoryFunc?
    nonisolated(unsafe) static var writeHistory: HistoryIOFunc?
    
    static var historyFilePath: String? {
        guard let home = ProcessInfo.processInfo.environment["HOME"] else { return nil }
        let dir = home + "/.cache/TurboFieldfareAgent"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true, attributes: nil)
        return dir + "/history.txt"
    }
    
    static func setup() {
        if let handle = dlopen("/usr/lib/libedit.dylib", RTLD_NOW) {
            typealias RlBindFunc = @convention(c) (UnsafePointer<CChar>?, UnsafePointer<CChar>?) -> Int32
            if let sym = dlsym(handle, "rl_variable_bind") {
                let bind = unsafeBitCast(sym, to: RlBindFunc.self)
                _ = bind("editing-mode", "emacs")
            }
            typealias VoidFunc = @convention(c) () -> Void
            if let sym = dlsym(handle, "using_history") {
                let usingHistory = unsafeBitCast(sym, to: VoidFunc.self)
                usingHistory()
            }
            if let sym = dlsym(handle, "readline") {
                readline = unsafeBitCast(sym, to: ReadlineFunc.self)
            }
            if let sym = dlsym(handle, "add_history") {
                addHistory = unsafeBitCast(sym, to: AddHistoryFunc.self)
            }
            if let sym = dlsym(handle, "read_history") {
                let readHistory = unsafeBitCast(sym, to: HistoryIOFunc.self)
                if let path = historyFilePath {
                    _ = readHistory(path)
                }
            }
            if let sym = dlsym(handle, "write_history") {
                writeHistory = unsafeBitCast(sym, to: HistoryIOFunc.self)
            }
        }
    }
    
    static func read(prompt: String) -> String? {
        if readline == nil { setup() }
        
        if let rl = readline {
            guard let cStr = rl(prompt) else { return nil }
            signal(SIGINT, { _ in print("\n[Agent Interrupted]"); exit(130) })
            defer { free(cStr) }
            
            let str = String(cString: cStr)
            if !str.isEmpty {
                addHistory?(cStr)
                if let path = historyFilePath {
                    _ = writeHistory?(path)
                }
            }
            return str
        } else {
            print(prompt, terminator: "")
            fflush(stdout)
            return Swift.readLine()
        }
    }
}

final class AgentState: @unchecked Sendable {
    var content = ""
    var calls: [ParsedToolCall] = []
}

// MARK: - AgentConfig
struct AgentConfig {
    let args: Args
    let systemPrompt: String
    
    init() throws {
        var rawArgv = Array(CommandLine.arguments.dropFirst())
        var systemPromptPath: String? = "docs/agent/codex_prompt.md"
        var agentsFilePath: String?
        
        var i = 0
        while i < rawArgv.count {
            if rawArgv[i] == "--system-prompt", i + 1 < rawArgv.count {
                systemPromptPath = rawArgv[i + 1]
                rawArgv.remove(at: i)
                rawArgv.remove(at: i)
            } else if rawArgv[i] == "--agents-file", i + 1 < rawArgv.count {
                agentsFilePath = rawArgv[i + 1]
                rawArgv.remove(at: i)
                rawArgv.remove(at: i)
            } else {
                i += 1
            }
        }
        
        if !rawArgv.contains("--prompt") && !rawArgv.contains("--chat-prompt") && !rawArgv.contains("--messages-file") {
            rawArgv.append("--prompt")
            rawArgv.append("agent")
        }
        
        do {
            self.args = try Args.parse(rawArgv)
        } catch ArgsError.helpRequested {
            print(Args.usage)
            exit(0)
        } catch {
            print("error: \(error)")
            exit(2)
        }
        
        var masterSystemPrompt = "You are a native Swift agent. You can execute tools natively.\n"
        if let path = systemPromptPath {
            if let content = try? String(contentsOfFile: path, encoding: .utf8) {
                masterSystemPrompt = content
            } else {
                printColor("Warning: Could not read system prompt at \(path)\n", color: "yellow")
            }
        }
        if let path = agentsFilePath {
            if let content = try? String(contentsOfFile: path, encoding: .utf8) {
                masterSystemPrompt += "\n\n## Agent Guidelines\n\(content)"
            } else {
                printColor("Warning: Could not read agents file at \(path)\n", color: "yellow")
            }
        }
        self.systemPrompt = masterSystemPrompt
    }
}

// MARK: - ToolRegistry
struct ToolRegistry {
    static let definitions: [GFTokenizer.FunctionDefinition] = [
        GFTokenizer.FunctionDefinition(
            name: "read_url",
            description: "Fetches the content of a URL and converts the HTML into readable Markdown text.",
            parameters: .object([
                "url": .object(["type": .string("string")])
            ])
        ),
        GFTokenizer.FunctionDefinition(
            name: "invoke_subagent",
            description: "Spawns a subagent to complete a complex sub-task. Use this to delegate long research or refactoring tasks.",
            parameters: .object([
                "prompt": .object(["type": .string("string")])
            ])
        ),
        GFTokenizer.FunctionDefinition(
            name: "code_nav_init",
            description: "Initialize tree-sitter AST index",
            parameters: .object(["reset": .object(["type": .string("string")])])
        ),
        GFTokenizer.FunctionDefinition(
            name: "code_symbols",
            description: "List top-level symbols in a file or directory",
            parameters: .object([
                "path": .object(["type": .string("string")])
            ])
        ),
        GFTokenizer.FunctionDefinition(
            name: "code_query",
            description: "Query AST using S-expressions",
            parameters: .object([
                "query": .object(["type": .string("string")])
            ])
        ),
        GFTokenizer.FunctionDefinition(
            name: "read_file",
            description: "Reads the contents of a file",
            parameters: .object([
                "path": .object(["type": .string("string")])
            ])
        ),
        GFTokenizer.FunctionDefinition(
            name: "write_file",
            description: "Writes content to a file",
            parameters: .object([
                "path": .object(["type": .string("string")]),
                "content": .object(["type": .string("string")])
            ])
        ),
        GFTokenizer.FunctionDefinition(
            name: "execute_bash",
            description: "Executes a shell command natively",
            parameters: .object([
                "command": .object(["type": .string("string")])
            ])
        )
    ]
    
    static func execute(call: ParsedToolCall, runtime: AgentRuntime) async -> String {
        if call.name == "invoke_subagent" {
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
                            printColor("\n🟢 \(c.name)(\(argString))\n", color: "green")
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
        if call.name == "code_nav_init" || call.name == "code_symbols" || call.name == "code_query" {
            guard let mcp = MCPClient.shared else { return "Error: MCP Client not initialized" }
            var args: [String: Any] = [:]
            if case .object(let map) = call.arguments {
                for (k, v) in map {
                    if case .string(let s) = v { args[k] = s }
                }
            }
            return mcp.callTool(name: call.name, args: args)
        }
        if call.name == "read_url" {
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
        if call.name == "read_file" {
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
        } else if call.name == "write_file" {
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
        } else if call.name == "execute_bash" {
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
        return "Error: unknown tool"
    }
}

// MARK: - AgentRuntime
class AgentRuntime {
    let context: MetalContext
    let model: Model
    let runner: RealForwardRunner
    let scratch: RawCompletionScratch
    let tokenizer: GFTokenizer
    let config: AgentConfig
    
    var previousPromptIds: [Int32] = []
    
    init(config: AgentConfig) async throws {
        self.config = config
        let modelURL = URL(fileURLWithPath: config.args.model)
        self.context = try MetalContext()
        let runtime = try config.args.resolvedRuntimeConfiguration(forceLogitsHead: true, imagePrompt: false)
        
        printColor("Loading Gemma 4 Agent from \(config.args.model)...\n", color: "blue")
        
        self.model = try Model.load(
            directoryURL: modelURL,
            device: context.device,
            streamingMode: .pread(slotCount: runtime.expertCacheSlots),
            expertCachePolicy: runtime.modelExpertCachePolicy,
            integrityPolicy: .fullSha256)
            
        self.runner = try RealForwardRunner(
            model: model,
            context: context,
            maxContext: config.args.maxContext,
            runtimeConfiguration: runtime)
            
        self.scratch = try RawCompletionScratch(context: context, vocab: model.config.vocabSize)
        self.tokenizer = try await GFTokenizer.load(forModelDirectory: modelURL)
    }
    
    func generate(messages: [GFTokenizer.Message]) async throws -> (content: String, calls: [ParsedToolCall]) {
        let promptIds = try tokenizer.encodeToolChat(messages: messages, tools: ToolRegistry.definitions)
        var matchCount = 0
        for i in 0..<min(previousPromptIds.count, promptIds.count) {
            if previousPromptIds[i] == promptIds[i] { matchCount += 1 }
            else { break }
        }
        
        let start: RawCompletionStart = matchCount > 0 ? .resume(cachedPromptTokens: matchCount) : .reset
        let decoder = StructuredAssistantDecoder(tokenizer: tokenizer, allowedTools: Set(ToolRegistry.definitions.map { $0.name }))
        
        
        
        let state = AgentState()
        
        let spinnerFrames = ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"]
        class SpinnerState: @unchecked Sendable {
            var isActive = true
            var hasStartedOutput = false
        }
        let sp = SpinnerState()
        
        let spinnerTask = Task {
            var i = 0
            while sp.isActive && !sp.hasStartedOutput {
                print("\r\u{001B}[34m\(spinnerFrames[i % spinnerFrames.count]) Thinking...\u{001B}[0m\u{001B}[K", terminator: "")
                fflush(stdout)
                try? await Task.sleep(nanoseconds: 80_000_000)
                i += 1
            }
            if !sp.hasStartedOutput {
                print("\r\u{001B}[K", terminator: "")
                fflush(stdout)
            }
        }
        
        _ = try await runRawCompletion(
            producer: runner,
            tokenizer: tokenizer,
            promptIds: promptIds,
            config: GenerationConfig(
                maxNewTokens: config.args.maxNew,
                temperature: config.args.temperature,
                topK: config.args.topK,
                topP: config.args.topP,
                repetitionPenalty: config.args.repetitionPenalty,
                seed: config.args.seed,
                stopStrings: config.args.stops,
                extraStopTokens: []
            ),
            context: context,
            scratch: scratch,
            start: start,
            onProgress: { event in
                switch event {
                case .prefill: break
                case .token(_, let tokenID, let delta):
                    let decoderEvents = (try? decoder.consume(tokenID: tokenID, delta: delta)) ?? []
                    for dev in decoderEvents {
                        switch dev {
                        case .content(let text):
                            if !sp.hasStartedOutput {
                                sp.hasStartedOutput = true
                                print("\r\u{001B}[K", terminator: "")
                            }
                            state.content += text
                            print(text, terminator: "")
                            fflush(stdout)
                        case .toolCall(let call):
                            state.calls.append(call)
                        }
                    }
                case .tail(let text):
                    let decoderEvents = (try? decoder.consumeTail(text)) ?? []
                    for dev in decoderEvents {
                        if case .content(let t) = dev {
                            if !sp.hasStartedOutput {
                                sp.hasStartedOutput = true
                                print("\r\u{001B}[K", terminator: "")
                            }
                            state.content += t
                            print(t, terminator: "")
                            fflush(stdout)
                        } else if case .toolCall(let call) = dev {
                            state.calls.append(call)
                        }
                    }
                }
            }
        )
        
        sp.isActive = false
        _ = await spinnerTask.result
        
        _ = try? decoder.finish()
        if sp.hasStartedOutput { print("") }
        
        self.previousPromptIds = []
        return (state.content, state.calls)
    }
}

// MARK: - AgentSession
class AgentSession {
    let runtime: AgentRuntime
    var messages: [GFTokenizer.Message]
    
    init(runtime: AgentRuntime) {
        self.runtime = runtime
        self.messages = [
            GFTokenizer.Message(role: .system, content: runtime.config.systemPrompt, toolCalls: [], toolCallID: nil, name: nil)
        ]
    }
    
    func startRepl() async throws {
        while true {
            print("")
            let prompt = "\u{01}\u{001B}[32m\u{02}Agent> \u{01}\u{001B}[0m\u{02}"
            guard let userInput = ReadlineWrapper.read(prompt: prompt) else { break }
            if userInput.isEmpty { continue }
            if userInput == "/exit" || userInput == "/quit" { break }
            
            if userInput.hasPrefix("!") {
                let cmdStr = String(userInput.dropFirst()).trimmingCharacters(in: .whitespaces)
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/bin/bash")
                process.arguments = ["-c", cmdStr]
                
                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = pipe
                
                printColor("\n🟢 Shell: \(cmdStr)\n", color: "green")
                try? process.run()
                process.waitUntilExit()
                
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                var outputStr = String(data: data, encoding: .utf8) ?? ""
                if outputStr.isEmpty { outputStr = "(No output)" }
                
                let displayRes = outputStr.count > 2000 ? String(outputStr.prefix(2000)) + "... (truncated)" : outputStr
                printColor("   \(displayRes)\n", color: "gray")
                
                let contextStr = "[User Executed Shell Command]: \(cmdStr)\n[Output]:\n\(displayRes)"
                messages.append(GFTokenizer.Message(role: .user, content: contextStr, toolCalls: [], toolCallID: nil, name: nil))
                continue
            }
            
            var finalInput = userInput
            if userInput.hasPrefix("/") {
                let parts = userInput.split(separator: " ", maxSplits: 1)
                if let command = parts.first {
                    let cmdName = String(command.dropFirst())
                    let args = parts.count > 1 ? String(parts[1]) : ""
                    
                    let skillPath = "docs/agent/skills/\(cmdName).md"
                    if let skillContent = try? String(contentsOfFile: skillPath, encoding: .utf8) {
                        printColor("[Loaded skill /\(cmdName) from \(skillPath)]\n", color: "blue")
                        finalInput = "[Skill: \(cmdName)]\n\(skillContent)\n\nUser Request:\n\(args)"
                    } else {
                        printColor("Warning: Skill '/\(cmdName)' not found at \(skillPath)\n", color: "yellow")
                        continue
                    }
                }
            }
            
            messages.append(GFTokenizer.Message(role: .user, content: finalInput, toolCalls: [], toolCallID: nil, name: nil))
            
            var turnActive = true
            while turnActive {
                do {
                    let (content, calls) = try await runtime.generate(messages: messages)
                    var hCalls: [GFTokenizer.HistoricalToolCall] = []
                    for call in calls {
                        hCalls.append(GFTokenizer.HistoricalToolCall(id: call.id, name: call.name, arguments: call.arguments))
                    }
                    messages.append(GFTokenizer.Message(role: .assistant, content: content.isEmpty ? nil : content, toolCalls: hCalls, toolCallID: nil, name: nil))
                    
                    if !calls.isEmpty {
                        for call in calls {
                            var argString = ""
                            if case .object(let map) = call.arguments {
                                if let c = map["command"], case .string(let s) = c { argString = s.replacingOccurrences(of: "\n", with: " ") }
                                else if let p = map["path"], case .string(let s) = p { argString = s }
                                else if let q = map["query"], case .string(let s) = q { argString = s }
                                else if let pr = map["prompt"], case .string(let s) = pr { argString = s }
                                else if let url = map["url"], case .string(let s) = url { argString = s }
                                else { argString = map.keys.joined(separator: ", ") }
                                if argString.count > 60 { argString = String(argString.prefix(60)) + "..." }
                            }
                            printColor("\n🟢 \(call.name)(\(argString))\n", color: "green")
                            let resultStr = await ToolRegistry.execute(call: call, runtime: runtime)
                            printColor("   \(resultStr.prefix(300))\(resultStr.count > 300 ? "..." : "")\n", color: "yellow")
                            messages.append(GFTokenizer.Message(role: .tool, content: resultStr, toolCalls: [], toolCallID: call.id, name: call.name))
                        }
                    } else {
                        turnActive = false
                    }
                } catch {
                    printColor("\n[Error: \(error)]\n", color: "yellow")
                    // Pop the offending message so the user can continue
                    if !messages.isEmpty { messages.removeLast() }
                    turnActive = false
                }
                }
            }
        }
    }

// MARK: - Main
@main
struct AgentCLI {
    static func main() async throws {
        let config = try AgentConfig()
        let runtime = try await AgentRuntime(config: config)
        let session = AgentSession(runtime: runtime)
        try await session.startRepl()
    }
}
