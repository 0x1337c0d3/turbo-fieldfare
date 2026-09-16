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

    let statusLine = AgentStatusLine()

    var remainingToolCalls = 64
    var subagentDepth = 0

    var committedTokenIDs: [Int32] = []

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
        let start = AgentPromptCache.start(
            prompt: promptIds, committed: committedTokenIDs,
            position: runner.continuationPosition, rewind: runner.rewind(to:))
        let cachedTokens: Int
        switch start {
        case .reset: cachedTokens = 0
        case .resume(let count): cachedTokens = count
        }
        // Any failure after this point may leave partially advanced KV state.
        // Only a successful completion supplies a trustworthy token record.
        committedTokenIDs.removeAll(keepingCapacity: true)
        let decoder = StructuredAssistantDecoder(tokenizer: tokenizer, allowedTools: Set(ToolRegistry.definitions.map { $0.name }))



        statusLine.beginGeneration(contextTokens: cachedTokens)

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
                        terminalPrint("\n[Force Exiting...]")
                        exit(1)
                    } else {
                        stopFlag.waitingForSecondCtrlC = false
                        continue // Let it naturally return to REPL since stop is already true
                    }
                }
                
                if c == 27 { // ESC
                    terminalPrint("\n[Generation Stopped (ESC)]")
                    stopFlag.stop = true
                    sp.isActive = false
                } else if c == 3 { // Ctrl-C
                    terminalPrint("\n[Press ctrl-c again to exit]")
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
            while sp.isActive && !sp.hasStartedOutput && !Task.isCancelled {
                terminalPrint("\r\u{001B}[34m\(spinnerFrames[i % spinnerFrames.count]) Thinking...\u{001B}[0m\u{001B}[K", terminator: "")
                fflush(stdout)
                try? await Task.sleep(nanoseconds: 80_000_000)
                i += 1
            }
            if !sp.hasStartedOutput {
                terminalPrint("\r\u{001B}[K", terminator: "")
                fflush(stdout)
            }
        }

        func handleDecoderEvents(_ events: [StructuredAssistantEvent]) {
            for event in events {
                switch event {
                case .content(let text):
                    if !sp.hasStartedOutput {
                        sp.hasStartedOutput = true
                        terminalPrint("\r\u{001B}[K", terminator: "")
                    }
                    state.content += text
                    terminalPrint(TerminalText.safe(text), terminator: "")
                case .toolCall(let call):
                    state.calls.append(call)
                    stopFlag.stop = true
                }
            }
        }

        let result: RawDecodeResult
        do {
            result = try await runRawCompletion(
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
                    case .prefill(let done, _):
                        self.statusLine.prefill(done: done)
                    case .token(let index, let tokenID, let delta):
                        self.statusLine.token(count: index + 1, contextTokens: promptIds.count + index)
                        handleDecoderEvents((try? decoder.consume(tokenID: tokenID, delta: delta)) ?? [])
                    case .tail(let text):
                        handleDecoderEvents((try? decoder.consumeTail(text)) ?? [])
                    }
                }
            )
        } catch {
            sp.isActive = false
            spinnerTask.cancel()
            _ = await spinnerTask.result
            statusLine.snapshot.phase = "Error"
            statusLine.refresh(force: true)
            throw error
        }

        sp.isActive = false
        _ = await spinnerTask.result

        _ = try? decoder.finish()
        if sp.hasStartedOutput { terminalPrint("") }

        statusLine.finish(tokens: result.newTokens, decodeSeconds: result.decodeSeconds, contextTokens: result.kvPosition)
        self.committedTokenIDs = result.kvBackedTokenIDs
        return (state.content, state.calls)
    }
}
