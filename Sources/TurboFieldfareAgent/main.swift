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
    default: colorCode = ""
    }
    print("\(colorCode)\(text)\u{001B}[0m", terminator: "")
    fflush(stdout)
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
            name: "execute_bash",
            description: "Executes a shell command natively",
            parameters: .object([
                "command": .object(["type": .string("string")])
            ])
        )
    ]
    
    static func execute(call: ParsedToolCall) -> String {
        printColor("[Executing Tool: \(call.name)]\n", color: "yellow")
        if call.name == "execute_bash" {
            if case .object(let argsMap) = call.arguments, case .string(let cmd) = argsMap["command"] {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/bin/bash")
                process.arguments = ["-c", cmd]
                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = pipe
                do {
                    try process.run()
                    process.waitUntilExit()
                    let data = pipe.fileHandleForReading.readDataToEndOfFile()
                    return String(data: data, encoding: .utf8) ?? ""
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
        
        printColor("Generating... ", color: "blue")
        
        let state = AgentState()
        
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
        
        _ = try? decoder.finish()
        print("")
        
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
            printColor("\nAgent> ", color: "green")
            guard let userInput = readLine() else { break }
            if userInput.isEmpty { continue }
            if userInput == "/exit" || userInput == "/quit" { break }
            
            messages.append(GFTokenizer.Message(role: .user, content: userInput, toolCalls: [], toolCallID: nil, name: nil))
            
            var turnActive = true
            while turnActive {
                let (content, calls) = try await runtime.generate(messages: messages)
                
                var hCalls: [GFTokenizer.HistoricalToolCall] = []
                for call in calls {
                    hCalls.append(GFTokenizer.HistoricalToolCall(id: call.id, name: call.name, arguments: call.arguments))
                }
                messages.append(GFTokenizer.Message(role: .assistant, content: content.isEmpty ? nil : content, toolCalls: hCalls, toolCallID: nil, name: nil))
                
                if !calls.isEmpty {
                    for call in calls {
                        let resultStr = ToolRegistry.execute(call: call)
                        printColor("\(resultStr)\n", color: "yellow")
                        messages.append(GFTokenizer.Message(role: .tool, content: resultStr, toolCalls: [], toolCallID: call.id, name: call.name))
                    }
                } else {
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
