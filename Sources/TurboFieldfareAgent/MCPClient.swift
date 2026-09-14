import Foundation

class MCPClient: @unchecked Sendable {
    static let shared = MCPClient()
    
    let process: Process
    let inPipe = Pipe()
    let outPipe = Pipe()
    var requestId = 1
    
    private init?() {
        process = Process()
        let serverPath = "/Users/peter/Development/AI/codex-nav-mcp-server/target/release/codex-nav-mcp-server"
        guard FileManager.default.fileExists(atPath: serverPath) else {
            print("MCP server not found at \\(serverPath)")
            return nil
        }
        
        process.executableURL = URL(fileURLWithPath: serverPath)
        process.standardInput = inPipe
        process.standardOutput = outPipe
        
        do {
            try process.run()
        } catch {
            print("Failed to run MCP server: \\(error)")
            return nil
        }
        
        // Init MCP
        let initReq = """
        {"jsonrpc":"2.0","id":0,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"turbo-agent","version":"1.0.0"}}}
        
        """
        inPipe.fileHandleForWriting.write(initReq.data(using: .utf8)!)
        _ = readLine() // consume response
        
        let initNotif = """
        {"jsonrpc":"2.0","method":"notifications/initialized"}
        
        """
        inPipe.fileHandleForWriting.write(initNotif.data(using: .utf8)!)
    }
    
    private func readLine() -> String {
        var data = Data()
        let handle = outPipe.fileHandleForReading
        while true {
            let byte = handle.readData(ofLength: 1)
            if byte.isEmpty { break }
            if byte == Data([10]) { break } // \n
            data.append(byte)
        }
        return String(data: data, encoding: .utf8) ?? ""
    }
    
    func callTool(name: String, args: [String: Any]) -> String {
        let reqId = requestId
        requestId += 1
        
        let argsData = (try? JSONSerialization.data(withJSONObject: args)) ?? Data()
        let argsJson = String(data: argsData, encoding: .utf8) ?? "{}"
        
        let req = """
        {"jsonrpc":"2.0","id":\(reqId),"method":"tools/call","params":{"name":"\(name)","arguments":\(argsJson)}}
        
        """
        inPipe.fileHandleForWriting.write(req.data(using: .utf8)!)
        
        // Read lines until we hit our response ID
        while true {
            let line = readLine()
            if line.isEmpty { return "Error: MCP Server disconnected" }
            if line.contains("\"id\":\(reqId)") {
                if let data = line.data(using: .utf8),
                   let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    if let error = dict["error"] as? [String: Any] {
                        let msg = error["message"] ?? "Unknown"; return "Error: \(msg)"
                    }
                    if let result = dict["result"] as? [String: Any],
                       let content = result["content"] as? [[String: Any]],
                       let text = content.first?["text"] as? String {
                        return text
                    }
                }
                return "Failed to parse result from MCP: \\(line)"
            }
        }
    }
}
