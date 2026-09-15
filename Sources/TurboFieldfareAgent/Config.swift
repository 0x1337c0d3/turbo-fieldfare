import Foundation
import TurboFieldfareCLICore

struct AgentConfig {
    let args: Args
    let systemPrompt: String

    init() throws {
        var rawArgv = Array(CommandLine.arguments.dropFirst())
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

        var masterSystemPrompt = ""
        
        let fm = FileManager.default
        let homeDir = fm.homeDirectoryForCurrentUser.path
        let localDir = fm.currentDirectoryPath
        
        func appendFile(at path: String, header: String? = nil) {
            if let content = try? String(contentsOfFile: path, encoding: .utf8) {
                if let header = header {
                    if !masterSystemPrompt.isEmpty { masterSystemPrompt += "\n\n" }
                    masterSystemPrompt += header + "\n"
                } else if !masterSystemPrompt.isEmpty {
                    masterSystemPrompt += "\n\n"
                }
                masterSystemPrompt += content
            }
        }
        
        func appendSkills(in directory: String) {
            let skillsDir = (directory as NSString).appendingPathComponent("skills")
            if let enumerator = fm.enumerator(atPath: skillsDir) {
                let files = enumerator.allObjects as? [String] ?? []
                for file in files.sorted() {
                    if file.hasSuffix(".md") {
                        let fullPath = (skillsDir as NSString).appendingPathComponent(file)
                        appendFile(at: fullPath, header: "## Skill: \(file)")
                    }
                }
            }
        }
        
        // 1. ~/.agents/codex_prompt.md
        let homeAgentsDir = (homeDir as NSString).appendingPathComponent(".agents")
        appendFile(at: (homeAgentsDir as NSString).appendingPathComponent("codex_prompt.md"))
        
        // 2. ~/.agents/skills/**
        appendSkills(in: homeAgentsDir)
        
        // 3. ./.agents/codex_prompt.md
        let localAgentsDir = (localDir as NSString).appendingPathComponent(".agents")
        appendFile(at: (localAgentsDir as NSString).appendingPathComponent("codex_prompt.md"))
        
        // 4. ./.agents/skills/**
        appendSkills(in: localAgentsDir)
        
        // 5. ./AGENTS.md (or custom agents file from CLI)
        if let customAgents = agentsFilePath {
            appendFile(at: customAgents, header: "## Agent Guidelines")
        } else {
            appendFile(at: (localDir as NSString).appendingPathComponent("AGENTS.md"), header: "## Agent Guidelines")
        }
        
        // Optionally append custom system prompt from CLI
        if let customPrompt = systemPromptPath {
            appendFile(at: customPrompt)
        }

        // Add MCP tool instructions (see 5)
        if !masterSystemPrompt.isEmpty {
            masterSystemPrompt += "\n\n"
        }
        masterSystemPrompt += "## MCP Tools\n"
        masterSystemPrompt += "MCP tools are available and can be called natively."

        if masterSystemPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            masterSystemPrompt = "You are a native Swift agent. You can execute tools natively.\n"
        }
        
        self.systemPrompt = masterSystemPrompt
    }
}
