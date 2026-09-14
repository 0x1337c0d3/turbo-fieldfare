# Subagent Delegation

You can now delegate tasks to isolated subagents using the `invoke_subagent` tool.

A subagent operates exactly like you do: it has a full context loop, access to all tools (including `read_file`, `write_file`, and `code_nav`), and it processes a task sequentially until it decides it has finished.

## When to use `invoke_subagent`
- **Large Refactors:** If a task requires modifying multiple files sequentially, spawning a subagent prevents your immediate context from overflowing with file dumps.
- **Deep Research:** If you need to trace a complex code path through many files using semantic search, a subagent can do the dirty work and report back just the summary.

## How to use it
Call `invoke_subagent` with a detailed `prompt`. 
Provide the subagent with EXACTLY what it needs to accomplish, and specifically request what information it should return to you in its final response.

Once the subagent is launched, you will see `--- [Subagent Started] ---` in the console. Your execution will pause until the subagent finishes, at which point you will receive its final response as the tool output.
