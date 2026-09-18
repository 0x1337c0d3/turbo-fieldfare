import Foundation
import TurboFieldfare

enum RoutingMode: String {
  case auto = "Auto (Hybrid)"
  case forceLocal = "Local (Embedded)"
  case forceCloud = "Remote (OpenAI)"
}

final class AgentState: @unchecked Sendable {
  var content = ""
  var calls: [ParsedToolCall] = []
}

// MARK: - AgentRuntime
// Access is serialized by the REPL or AgentCore.
final class AgentRuntime: @unchecked Sendable {
  let context: MetalContext
  let model: Model
  let runner: RealForwardRunner
  let scratch: RawCompletionScratch
  let tokenizer: GFTokenizer
  let config: AgentConfig

  let statusLine = AgentStatusLine()

  var remainingToolCalls = 64
  var subagentDepth = 0

  var lastStopReason: StopReason = .endOfTurn

  var routingMode: RoutingMode = .auto
  var openAIClient: OpenAIClient? = OpenAIClient()

  var committedTokenIDs: [Int32] = []

  init(config: AgentConfig) async throws {
    self.config = config

    if let rm = config.routingMode {
      switch rm {
      case "local": self.routingMode = .forceLocal
      case "cloud": self.routingMode = .forceCloud
      case "auto": self.routingMode = .auto
      default: break
      }
    }

    let modelURL = URL(fileURLWithPath: config.args.model)
    self.context = try MetalContext()
    let runtime = try config.args.resolvedRuntimeConfiguration(
      forceLogitsHead: true, imagePrompt: false)

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

  func generate(
    messages: [GFTokenizer.Message],
    tools: [GFTokenizer.FunctionDefinition]? = nil,
    interaction: AgentInteraction? = nil, forceLocal: Bool = false
  ) async throws -> (content: String, calls: [ParsedToolCall]) {
    let definitions = tools ?? ToolRegistry.definitions

    var target: RouteTarget = .local
    if forceLocal {
      target = .local
    } else {
      switch routingMode {
      case .forceLocal:
        target = .local
      case .forceCloud:
        target = .cloud
      case .auto:
        let router = HybridRouter(localRuntime: self, cloudClient: openAIClient)
        target = try await router.decide(messages: messages)
      }
    }

    if target == .cloud, let client = openAIClient {
      if interaction == nil {
        terminalPrint("\n\u{001B}[33m[Auto-Routed to Cloud (OpenAI)]\u{001B}[0m\n")
      }

      let cancellation = interaction?.cancellation ?? AgentCancellation()
      let terminal = (interaction == nil) ? TerminalGeneration(cancellation: cancellation) : nil

      do {
        let result = try await client.generate(messages: messages, tools: definitions)

        if let interaction {
          interaction.text(result.content)
        } else {
          terminal?.text(result.content)
        }

        await terminal?.finish()
        lastStopReason = .endOfTurn
        return result
      } catch {
        await terminal?.finish()
        if interaction == nil {
          terminalPrint(
            "\n\u{001B}[31m[Cloud route failed: \(error). Falling back to Local...]\u{001B}[0m\n")
        }
        return try await generateLocally(
          messages: messages, tools: definitions, interaction: interaction)
      }
    } else {
      if routingMode == .auto && interaction == nil {
        terminalPrint("\n\u{001B}[32m[Auto-Routed to Local (Embedded)]\u{001B}[0m\n")
      }
      do {
        return try await generateLocally(
          messages: messages, tools: definitions, interaction: interaction)
      } catch {
        if let client = openAIClient {
          if interaction == nil {
            terminalPrint(
              "\n\u{001B}[31m[Local route failed: \(error). Falling back to Cloud...]\u{001B}[0m\n")
          }
          let result = try await client.generate(messages: messages, tools: definitions)
          if interaction == nil {
            terminalPrint(result.content)
          } else {
            interaction?.text(result.content)
          }
          lastStopReason = .endOfTurn
          return result
        } else {
          throw error
        }
      }
    }
  }

  func generateLocally(
    messages: [GFTokenizer.Message],
    tools: [GFTokenizer.FunctionDefinition]? = nil,
    interaction: AgentInteraction? = nil,
    maxNewTokensOverride: Int? = nil,
    silent: Bool = false
  ) async throws -> (content: String, calls: [ParsedToolCall]) {
    let definitions = tools ?? ToolRegistry.definitions
    let promptIds = try tokenizer.encodeToolChat(messages: messages, tools: definitions)
    let start = AgentPromptCache.start(
      prompt: promptIds, committed: committedTokenIDs,
      position: runner.continuationPosition, rewind: runner.rewind(to:))
    let cachedTokens: Int
    switch start {
    case .reset: cachedTokens = 0
    case .resume(let count): cachedTokens = count
    }

    if !silent { committedTokenIDs.removeAll(keepingCapacity: true) }
    let decoder = StructuredAssistantDecoder(
      tokenizer: tokenizer, allowedTools: Set(definitions.map { $0.name }))

    if interaction == nil && !silent { statusLine.beginGeneration(contextTokens: cachedTokens) }
    let state = AgentState()
    let cancellation = interaction?.cancellation ?? AgentCancellation()
    let stopAfterTool = AgentCancellation()
    let terminal =
      (interaction == nil && !silent) ? TerminalGeneration(cancellation: cancellation) : nil
    defer { terminal?.restore() }

    func handleDecoderEvents(_ events: [StructuredAssistantEvent]) {
      for event in events {
        switch event {
        case .content(let text):
          state.content += text
          if !silent {
            if let interaction { interaction.text(text) } else { terminal?.text(text) }
          }
        case .thought(let text):
          if !silent {
            terminal?.thought(text)
          }
        case .toolCall(let call):
          state.calls.append(call)
          stopAfterTool.cancel()
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
          maxNewTokens: maxNewTokensOverride ?? config.args.maxNew,
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
        shouldStop: { stopAfterTool.isCancelled || cancellation.isCancelled || Task.isCancelled },
        onProgress: { event in
          switch event {
          case .prefill(let done, _):
            if interaction == nil && !silent { self.statusLine.prefill(done: done) }
          case .token(let index, let tokenID, let delta):
            if interaction == nil && !silent {
              self.statusLine.token(count: index + 1, contextTokens: promptIds.count + index)
            }
            handleDecoderEvents((try? decoder.consume(tokenID: tokenID, delta: delta)) ?? [])
          case .tail(let text):
            handleDecoderEvents((try? decoder.consumeTail(text)) ?? [])
          }
        }
      )
    } catch {
      if !silent {
        await terminal?.finish()
        statusLine.snapshot.phase = "Error"
        statusLine.refresh(force: true)
      }
      throw error
    }

    if !silent { await terminal?.finish() }
    _ = try? decoder.finish()

    if interaction == nil && !silent {
      statusLine.finish(
        tokens: result.newTokens, decodeSeconds: result.decodeSeconds,
        contextTokens: result.kvPosition)
    }

    if !silent {
      lastStopReason = result.reason
      if interaction?.cancellation.isCancelled == true || Task.isCancelled {
        committedTokenIDs.removeAll()
        throw CancellationError()
      }
      self.committedTokenIDs = result.kvBackedTokenIDs
    }
    return (state.content, state.calls)
  }
}
