import Foundation
import TurboFieldfare

final class AgentState: @unchecked Sendable {
    var content = ""
    var calls: [ParsedToolCall] = []
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



        var currentTokens = promptIds

        let state = AgentState()

        let spinnerFrames = ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"]
        class SpinnerState: @unchecked Sendable {
            var isActive = true
            var hasStartedOutput = false
        }

        class StopFlag: @unchecked Sendable {
            var stop = false
            var waitingForSecondCtrlC = false
        }
        let stopFlag = StopFlag()
        let sp = SpinnerState()
        
        var originalTermios = termios()
        tcgetattr(STDIN_FILENO, &originalTermios)
        var raw = originalTermios
        raw.c_lflag &= ~UInt(ICANON | ECHO | ISIG)
        raw.c_cc.16 = 1
        raw.c_cc.17 = 0
        tcsetattr(STDIN_FILENO, TCSANOW, &raw)
        let originalFlags = fcntl(STDIN_FILENO, F_GETFL, 0)
        _ = fcntl(STDIN_FILENO, F_SETFL, originalFlags | O_NONBLOCK)
        
        let keyboardSource = DispatchSource.makeReadSource(fileDescriptor: STDIN_FILENO, queue: .global())
        keyboardSource.setEventHandler {
            var c: UInt8 = 0
            while read(STDIN_FILENO, &c, 1) > 0 {
                if stopFlag.waitingForSecondCtrlC {
                    if c == 3 { // Ctrl-C
                        print("\n[Force Exiting...]")
                        exit(1)
                    } else {
                        stopFlag.waitingForSecondCtrlC = false
                        continue // Let it naturally return to REPL since stop is already true
                    }
                }
                
                if c == 27 { // ESC
                    print("\n[Generation Stopped (ESC)]")
                    stopFlag.stop = true
                    sp.isActive = false
                } else if c == 3 { // Ctrl-C
                    print("\n[Press ctrl-c again to exit]")
                    stopFlag.waitingForSecondCtrlC = true
                    stopFlag.stop = true
                    sp.isActive = false
                }
            }
        }
        keyboardSource.resume()
        
        defer { 
            keyboardSource.cancel()
            _ = fcntl(STDIN_FILENO, F_SETFL, originalFlags)
            tcsetattr(STDIN_FILENO, TCSANOW, &originalTermios)
        }


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
            shouldStop: { stopFlag.stop || Task.isCancelled },
            onProgress: { event in
                switch event {
                case .prefill: break
                case .token(_, let tokenID, let delta):
                    currentTokens.append(tokenID)
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
                            stopFlag.stop = true
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
                            stopFlag.stop = true
                        }
                    }
                }
            }
        )

        sp.isActive = false
        _ = await spinnerTask.result

        _ = try? decoder.finish()
        if sp.hasStartedOutput { print("") }

        self.previousPromptIds = currentTokens
        return (state.content, state.calls)
    }
}
