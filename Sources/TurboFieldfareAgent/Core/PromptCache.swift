import TurboFieldfare

/// A prefix is reusable only when it describes the runner's committed KV state.
enum AgentPromptCache {
    static func start(
        prompt: [Int32], committed: [Int32], position: Int,
        rewind: (Int) throws -> Void
    ) -> RawCompletionStart {
        guard position > 0, committed.count == position, prompt.count > 1 else {
            return .reset
        }
        // Keep at least one prompt token to compute the next-token logits.
        let limit = min(committed.count, prompt.count - 1)
        var matched = 0
        while matched < limit, committed[matched] == prompt[matched] {
            matched += 1
        }
        guard matched > 0 else { return .reset }
        if matched != position {
            do {
                try rewind(matched)
            } catch {
                // Sliding-window KV may have overwritten the earlier state.
                return .reset
            }
        }
        return .resume(cachedPromptTokens: matched)
    }
}
