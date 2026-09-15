import TurboFieldfareCLICore
import Foundation

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
