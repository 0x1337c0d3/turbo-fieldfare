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
  let config: AgentConfig
  let backend: any InferenceBackend
  let gemmaBackend: MetalGemmaBackend?
  let statusLine = AgentStatusLine()

  var remainingToolCalls = 64
  var subagentDepth = 0

  var lastStopReason: StopReason = .endOfTurn

  var routingMode: RoutingMode = .auto
  var openAIClient: OpenAIClient? = OpenAIClient()

  var committedTokenIDs: [Int32] {
    get { gemmaBackend?.committedTokenIDs ?? _committedTokenIDs }
    set {
      _committedTokenIDs = newValue
      gemmaBackend?.committedTokenIDs = newValue
    }
  }
  private var _committedTokenIDs: [Int32] = []

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

    switch config.backend {
    case .apple:
      #if canImport(FoundationModels)
        if #available(macOS 27.0, *) {
          self.backend = AppleFoundationModelBackend(
            pccPolicy: config.pccPolicy,
            systemPrompt: config.systemPrompt
          )
          self.gemmaBackend = nil
        } else {
          printColor(
            "[Apple Foundation Models require macOS 27.0 (Golden Gate) or later. Falling back to Gemma...]\n",
            color: "yellow")
          let gemmaPath =
            (config.args.model == "none" || config.args.model.isEmpty)
            ? config.defaultModelURL.path : config.args.model
          if FileManager.default.fileExists(atPath: gemmaPath) {
            let gemma = try await MetalGemmaBackend(config: config, statusLine: statusLine)
            self.backend = gemma
            self.gemmaBackend = gemma
          } else if let openAI = openAIClient {
            printColor(
              "[Gemma model not found at \(gemmaPath). Falling back to OpenAI...]\n",
              color: "yellow")
            self.backend = try OpenAICompatibleBackend(client: openAI)
            self.gemmaBackend = nil
          } else {
            let gemma = try await MetalGemmaBackend(config: config, statusLine: statusLine)
            self.backend = gemma
            self.gemmaBackend = gemma
          }
        }
      #else
        printColor(
          "[Apple Foundation Models require macOS 27.0 (Golden Gate) or later with FoundationModels. Falling back to Gemma...]\n",
          color: "yellow")
        let gemmaPath =
          (config.args.model == "none" || config.args.model.isEmpty)
          ? config.defaultModelURL.path : config.args.model
        if FileManager.default.fileExists(atPath: gemmaPath) {
          let gemma = try await MetalGemmaBackend(config: config, statusLine: statusLine)
          self.backend = gemma
          self.gemmaBackend = gemma
        } else if let openAI = openAIClient {
          printColor(
            "[Gemma model not found at \(gemmaPath). Falling back to OpenAI...]\n",
            color: "yellow")
          self.backend = try OpenAICompatibleBackend(client: openAI)
          self.gemmaBackend = nil
        } else {
          let gemma = try await MetalGemmaBackend(config: config, statusLine: statusLine)
          self.backend = gemma
          self.gemmaBackend = gemma
        }
      #endif

    case .gemma:
      let gemma = try await MetalGemmaBackend(config: config, statusLine: statusLine)
      self.backend = gemma
      self.gemmaBackend = gemma

    case .openai:
      self.backend = try OpenAICompatibleBackend(client: openAIClient)
      self.gemmaBackend = nil
    }
  }

  func generate(
    messages: [GFTokenizer.Message],
    tools: [GFTokenizer.FunctionDefinition]? = nil,
    interaction: AgentInteraction? = nil, forceLocal: Bool = false
  ) async throws -> (content: String, calls: [ParsedToolCall]) {
    let definitions = tools ?? ToolRegistry.definitions

    if config.backend == .apple {
      if interaction == nil {
        switch config.pccPolicy {
        case .disable:
          printColor("[AFM 3 Core: 100% On-Device execution]\n", color: "green")
        case .require:
          printColor("[AFM Cloud Pro: Private Cloud Compute session]\n", color: "yellow")
        case .auto:
          printColor(
            "[Apple Foundation Models: AFM 3 Core (On-Device) / PCC (Auto)]\n", color: "blue")
        }
      }
      return try await backend.generate(
        messages: messages, tools: definitions, interaction: interaction)
    }

    if config.backend == .openai {
      return try await backend.generate(
        messages: messages, tools: definitions, interaction: interaction)
    }

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
        let router = HybridRouter(
          backendKind: config.backend,
          pccPolicy: config.pccPolicy,
          localRuntime: self,
          cloudClient: openAIClient
        )
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
    if let gemma = gemmaBackend {
      let result = try await gemma.generateLocally(
        messages: messages,
        tools: tools,
        interaction: interaction,
        maxNewTokensOverride: maxNewTokensOverride,
        silent: silent
      )
      self.lastStopReason = gemma.lastStopReason
      return result
    } else {
      return try await backend.generate(messages: messages, tools: tools, interaction: interaction)
    }
  }
}
