import Foundation
import TurboFieldfareCLICore

public enum AgentBackendKind: String, Sendable, CaseIterable {
  case apple = "apple"
  case gemma = "gemma"
  case openai = "openai"
}

public enum PCCPolicy: String, Sendable, CaseIterable {
  case auto = "auto"
  case disable = "disable"
  case require = "require"
}

public enum AgentConfigError: Error, CustomStringConvertible {
  case invalidBackend(String)
  case invalidPCCPolicy(String)

  public var description: String {
    switch self {
    case .invalidBackend(let val):
      return "Invalid backend: '\(val)'. Supported backends are: apple, gemma, openai."
    case .invalidPCCPolicy(let val):
      return "Invalid PCC policy: '\(val)'. Supported policies are: auto, disable, require."
    }
  }
}

public struct AgentConfig: Sendable {
  public let args: Args
  public let systemPrompt: String
  public let routingMode: String?
  public let backend: AgentBackendKind
  public let pccPolicy: PCCPolicy
  public let defaultModelURL: URL

  public init(
    arguments: [String] = Array(CommandLine.arguments.dropFirst()),
    homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
    workingDirectory: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
  ) throws {
    let parsed = try Self.parseArguments(arguments, homeDirectory: homeDirectory)
    self.args = parsed.args
    self.routingMode = parsed.routingMode
    self.backend = parsed.backend
    self.pccPolicy = parsed.pccPolicy
    self.defaultModelURL =
      homeDirectory
      .appendingPathComponent("Library/Application Support/TurboFieldfare/gemma4.gturbo")
    self.systemPrompt = Self.buildSystemPrompt(
      homeDirectory: homeDirectory, workingDirectory: workingDirectory,
      agentsFilePath: parsed.agentsFilePath, systemPromptPath: parsed.systemPromptPath)
  }

  private static func parseArguments(
    _ arguments: [String], homeDirectory: URL
  ) throws -> (
    args: Args,
    agentsFilePath: String?,
    systemPromptPath: String?,
    routingMode: String?,
    backend: AgentBackendKind,
    pccPolicy: PCCPolicy
  ) {
    var rawArgv = arguments
    var systemPromptPath: String?
    var agentsFilePath: String?
    var routingMode: String?
    var backendArg: String?
    var pccArg: String?
    let userSpecifiedModel = rawArgv.contains("--model")

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
      } else if rawArgv[i] == "--routing-mode", i + 1 < rawArgv.count {
        routingMode = rawArgv[i + 1]
        rawArgv.remove(at: i)
        rawArgv.remove(at: i)
      } else if rawArgv[i] == "--backend", i + 1 < rawArgv.count {
        backendArg = rawArgv[i + 1]
        rawArgv.remove(at: i)
        rawArgv.remove(at: i)
      } else if rawArgv[i] == "--pcc", i + 1 < rawArgv.count {
        pccArg = rawArgv[i + 1]
        rawArgv.remove(at: i)
        rawArgv.remove(at: i)
      } else {
        i += 1
      }
    }

    let backend: AgentBackendKind
    if let backendArg {
      guard let kind = AgentBackendKind(rawValue: backendArg.lowercased()) else {
        throw AgentConfigError.invalidBackend(backendArg)
      }
      backend = kind
    } else {
      if userSpecifiedModel {
        backend = .gemma
      } else if #available(macOS 27.0, *) {
        backend = .apple
      } else {
        backend = .gemma
      }
    }

    let pccPolicy: PCCPolicy
    if let pccArg {
      guard let policy = PCCPolicy(rawValue: pccArg.lowercased()) else {
        throw AgentConfigError.invalidPCCPolicy(pccArg)
      }
      pccPolicy = policy
    } else {
      pccPolicy = .auto
    }

    let defaultModel =
      homeDirectory
      .appendingPathComponent("Library/Application Support/TurboFieldfare/gemma4.gturbo")
    if !rawArgv.contains("--model") {
      if backend == .gemma {
        rawArgv.append(contentsOf: ["--model", defaultModel.path])
      } else {
        rawArgv.append(contentsOf: ["--model", "none"])
      }
    }

    if !rawArgv.contains("--max-context") {
      rawArgv.append(contentsOf: ["--max-context", "262144"])
    }

    if !rawArgv.contains("--prompt") && !rawArgv.contains("--chat-prompt")
      && !rawArgv.contains("--messages-file")
    {
      rawArgv.append("--prompt")
      rawArgv.append("agent")
    }

    let parsedArgs: Args
    do {
      parsedArgs = try Args.parse(rawArgv)
    } catch ArgsError.helpRequested {
      print(Args.usage)
      exit(0)
    } catch {
      throw error
    }

    return (parsedArgs, agentsFilePath, systemPromptPath, routingMode, backend, pccPolicy)
  }

  private static func buildSystemPrompt(
    homeDirectory: URL, workingDirectory: URL,
    agentsFilePath: String?, systemPromptPath: String?
  ) -> String {
    var masterSystemPrompt = ""

    let homeDir = homeDirectory.path
    let localDir = workingDirectory.path

    func appendFile(at path: String, header: String? = nil) {
      guard let content = try? String(contentsOfFile: path, encoding: .utf8) else { return }
      if !masterSystemPrompt.isEmpty { masterSystemPrompt += "\n\n" }
      if let header { masterSystemPrompt += header + "\n" }
      masterSystemPrompt += content
    }

    if let customPrompt = systemPromptPath {
      appendFile(at: customPrompt)
    } else {
      // Global instructions, then project instructions.
      let homeAgentsDir = (homeDir as NSString).appendingPathComponent(".agents")
      appendFile(at: (homeAgentsDir as NSString).appendingPathComponent("codex_prompt.md"))

      // Project prompt.
      let localAgentsDir = (localDir as NSString).appendingPathComponent(".agents")
      appendFile(at: (localAgentsDir as NSString).appendingPathComponent("codex_prompt.md"))
    }

    // Project guidelines or the explicitly selected file.
    if let customAgents = agentsFilePath {
      appendFile(at: customAgents, header: "## Agent Guidelines")
    } else {
      appendFile(
        at: (localDir as NSString).appendingPathComponent("AGENTS.md"),
        header: "## Agent Guidelines")
    }

    // Keep skill bodies and their reference documents out of every prompt.
    masterSystemPrompt += """


      ## Skills
      Skills are loaded on demand. The user can list skills with /skills and
      invoke /<skill> [request] to include that skill's instructions.
      Skill files live under ~/.agents/skills/ and ./.agents/skills/ as
      <name>.md or <name>/SKILL.md. Read supporting files only when needed
      for the active task; do not load the entire skill library.
      """

    // Add MCP tool instructions
    if !masterSystemPrompt.isEmpty {
      masterSystemPrompt += "\n\n"
    }
    masterSystemPrompt += "## MCP Tools\n"
    masterSystemPrompt += "MCP tools are available and can be called natively.\n\n"
    masterSystemPrompt += "## Autonomous Execution Policy\n"
    masterSystemPrompt +=
      "You are an autonomous software engineering agent. If a user prompt, workflow description, or task suggests pausing for human review (such as 'after review of the documentation'), do NOT pause or halt your turn to wait for confirmation. Instead, proceed directly to implementation and validation. Always create the requested deliverable files using `write_file`. Even if an optimal or deterministic algorithm has not been mathematically proven, you must still write your best-effort implementation to the requested destination file, run tests or code to verify its behavior, and report your findings. Never abandon file creation or exit with an empty turn without creating the requested files."

    if masterSystemPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      masterSystemPrompt = "You are a native Swift agent. You can execute tools natively.\n"
    }

    return masterSystemPrompt
  }
}

// MCP settings use JSON; environment header values are variable names, not templates.
struct AgentMCPConfig: Decodable, Sendable {
  struct ServerConfig: Decodable, Sendable {
    let command: String?
    let args: [String]?
    let env: [String: String]?
    let type: String?
    let url: String?
    let headers: [String: String]?
    let httpHeaders: [String: String]?
    let envHttpHeaders: [String: String]?

    enum CodingKeys: String, CodingKey {
      case command, args, env, type, url, headers
      case httpHeaders = "http_headers"
      case envHttpHeaders = "env_http_headers"
    }

    func resolvedHeaders(environment: [String: String] = ProcessInfo.processInfo.environment) throws
      -> [String: String]
    {
      var result: [String: String] = [:]
      // HTTP header names are case-insensitive. Environment values win.
      for source in [headers ?? [:], httpHeaders ?? [:]] {
        for (name, value) in source { result[name.lowercased()] = value }
      }
      for (name, variable) in envHttpHeaders ?? [:] {
        guard let value = environment[variable], !value.isEmpty else {
          throw HeaderError.missingEnvironmentVariable(variable)
        }
        result[name.lowercased()] = value
      }
      return result
    }
  }

  enum HeaderError: Error, CustomStringConvertible {
    case missingEnvironmentVariable(String)

    var description: String {
      switch self {
      case .missingEnvironmentVariable(let name):
        return "Required MCP header environment variable \(name) is unset or empty"
      }
    }
  }

  let mcpServers: [String: ServerConfig]?
}
