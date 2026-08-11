# ``ACPA2ABridge``

A bridge module that publishes a swift-a2a agent as an ACP agent.

> **Unofficial.** Not affiliated with or endorsed by the authors of the Agent Client Protocol or the A2A protocol, and built on unofficial Swift implementations of both. Conforming to either specification is not a goal of this project.

## Overview

`ACPA2ABridge` is the adapter layer that connects ACP (Agent Communication Protocol) and the A2A (Agent-to-Agent) protocol.
`A2AAgentBridge` alone is enough to present any `RequestHandler` (usually a `DefaultRequestHandler` given an `AgentExecutor`) to an ACP host as an `ACPAgent`.

The bridge is responsible for these conversions.

- **ACP → A2A**: Converts an ACP `PromptRequest` (a list of `ContentBlock`s) into an A2A `Message` and
  calls the handler's `onMessageSendStream`.
- **A2A → ACP**: Maps the `StreamResponse` the handler returns onto an ACP `session/update` notification
  (`agentMessageChunk`) and sends it. Artifacts and messages are sent unconditionally, a statusUpdate is sent only when it carries a message, and a task is used only to detect the terminal state.
- **Termination**: Converts the A2A task's terminal state (`completed` / `canceled` / `rejected` / `failed`)
  into an ACP `StopReason` and returns a `PromptResponse`.

### Basic usage

```swift
import ACPA2ABridge
import A2AServer
import ACPAgent

// 1. Prepare an A2A handler (give it your own AgentExecutor implementation)
let card = AgentCard(
    name: "MyAgent",
    description: "My A2A agent.",
    supportedInterfaces: [AgentInterface(url: "acp://local", protocolBinding: "JSONRPC")],
    version: "1.0",
    capabilities: AgentCapabilities(streaming: true)
)
let handler = DefaultRequestHandler(agentCard: card, executor: MyAgentExecutor())

// 2. Combine it with an ACP client to create the bridge
let bridge = A2AAgentBridge(client: acpClient, handler: handler)

// 3. Just hand it to an ACP host — the host never knows A2A is there
let response = try await bridge.prompt(
    PromptRequest(sessionId: "session-1", prompt: [.text(TextContent(text: "Hello"))])
)
print(response.stopReason) // .endTurn
```

Session management (`initialize`, `newSession`, `cancel`) is provided by the bridge as a minimal implementation.
Methods this bridge does not support, such as `authenticate` and `loadSession`, return a `.methodNotFound` error.

## Topics

### The bridge

- ``A2AAgentBridge``
