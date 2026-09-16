import Foundation
import TurboFieldfareCLICore

struct AgentConfig: Sendable {
    let args: Args
    let systemPrompt: String

    init(arguments: [String] = Array(CommandLine.arguments.dropFirst()),
         homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
         workingDirectory: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)) throws {
        let parsed = try Self.parseArguments(arguments, homeDirectory: homeDirectory)
        self.args = parsed.args
        self.systemPrompt = Self.buildSystemPrompt(
            homeDirectory: homeDirectory, workingDirectory: workingDirectory,
            agentsFilePath: parsed.agentsFilePath, systemPromptPath: parsed.systemPromptPath)
    }

    private static func parseArguments(
        _ arguments: [String], homeDirectory: URL
    ) throws -> (args: Args, agentsFilePath: String?, systemPromptPath: String?) {
        var rawArgv = arguments
        var systemPromptPath: String?
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

        if !rawArgv.contains("--model") {
            let defaultModel = homeDirectory
                .appendingPathComponent("Library/Application Support/TurboFieldfare/gemma4.gturbo")
            rawArgv.append(contentsOf: ["--model", defaultModel.path])
        }

        if !rawArgv.contains("--max-context") {
            rawArgv.append(contentsOf: ["--max-context", "262144"])
        }

        if !rawArgv.contains("--prompt") && !rawArgv.contains("--chat-prompt") && !rawArgv.contains("--messages-file") {
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

        return (parsedArgs, agentsFilePath, systemPromptPath)
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
        
        // Global instructions, then project instructions.
        let homeAgentsDir = (homeDir as NSString).appendingPathComponent(".agents")
        appendFile(at: (homeAgentsDir as NSString).appendingPathComponent("codex_prompt.md"))
        
        // Project prompt.
        let localAgentsDir = (localDir as NSString).appendingPathComponent(".agents")
        appendFile(at: (localAgentsDir as NSString).appendingPathComponent("codex_prompt.md"))
        
        // Project guidelines or the explicitly selected file.
        if let customAgents = agentsFilePath {
            appendFile(at: customAgents, header: "## Agent Guidelines")
        } else {
            appendFile(at: (localDir as NSString).appendingPathComponent("AGENTS.md"), header: "## Agent Guidelines")
        }
        
        // Optionally append custom system prompt from CLI
        if let customPrompt = systemPromptPath {
            appendFile(at: customPrompt)
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
        masterSystemPrompt += "MCP tools are available and can be called natively."

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
        let http_headers: [String: String]?
        let env_http_headers: [String: String]?

        func resolvedHeaders(environment: [String: String] = ProcessInfo.processInfo.environment) throws -> [String: String] {
            var result: [String: String] = [:]
            // HTTP header names are case-insensitive. Environment values win.
            for source in [headers ?? [:], http_headers ?? [:]] {
                for (name, value) in source { result[name.lowercased()] = value }
            }
            for (name, variable) in env_http_headers ?? [:] {
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
