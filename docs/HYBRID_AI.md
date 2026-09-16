# Hybrid AI Architecture

TurboFieldfareAgent implements a fully automated Hybrid AI routing policy. This allows the system to combine the privacy, low latency, and zero cost of local embedded inference with the powerful reasoning capabilities of remote cloud LLMs (via an OpenAI-compatible API endpoint).

This architecture is modeled after the "Hybrid AI" classification approach (e.g., Microsoft Foundry).

## Architecture Overview

When a prompt is submitted in the REPL, the agent routes it through a two-stage classification pipeline *before* executing the generation.

```text
User prompt
     │
     ▼
 HybridRouter.decide()
     │
     ├─► Stage 1: Heuristic Classifier (Deterministic, Zero model calls)
     │       ├─► Evaluates string length, keywords ("generate image", etc.)
     │       └─► Returns `.cloud` or `.local`, else passes to Stage 2
     │
     └─► Stage 2: Router LLM (Local classification)
             ├─► Bypasses standard UI reporting
             ├─► Pushes the prompt to the local Gemma 4 model with max tokens = 5
             └─► Classifies the intent as `.cloud` or `.local`
     │
     ▼
 AgentRuntime.generate()
     │
     ├─── RouteTarget.local ──► Local Embedded Inference
     │                               └─► Cloud fallback if local generation fails
     │
     └─── RouteTarget.cloud ──► OpenAIClient HTTP request
                                     └─► Local fallback if cloud generation fails
```

## Implementation Details

### Configuration
The system automatically discovers your API credentials by parsing `~/.config/TurboFieldfareAgent/settings.json`. It will expand variables from the environment (e.g. `$OPENAI_API_KEY`).
```json
{
    "openai_api_key": "$OPENAI_API_KEY",
    "openai_base_url": "https://api.openai.com/v1/",
    "openai_model": "gpt-4o"
}
```
*Note: The HTTP client sends `Authorization: Bearer`, `api-key`, and `x-api-key` headers simultaneously to guarantee compatibility with native OpenAI, Microsoft Foundry (Azure OpenAI), and various other vendor proxies.*

### Manual Override (Shift-Tab)
While the `HybridRouter` operates fully automatically by default, you can force the routing path by pressing `Shift-Tab` in the REPL. This keybind cycles between three `RoutingMode` states:
1. **Auto (Hybrid)**: The default state. Let the heuristics and local LLM decide.
2. **Remote (OpenAI)**: Forces all requests to `.cloud`.
3. **Local (Embedded)**: Forces all requests to `.local`.

When changed, the CLI will output a visual indicator, e.g., `[Switched to Auto (Hybrid)]`.

### Dynamic Fallbacks
The `AgentRuntime` leverages Swift's `do/catch` control flow for fallback resilience. If the primary target route raises an error (for example, if the OpenAI API returns a `429 Too Many Requests`, or the local model hits an `Out of Memory` context size error), the runtime automatically and transparently reroutes the task to the secondary provider.
