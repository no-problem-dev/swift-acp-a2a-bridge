# swift-acp-a2a-bridge

Exposes a [swift-a2a](https://github.com/no-problem-dev/swift-a2a) agent as an
[ACP](https://agentclientprotocol.com) agent — the connection layer that lets an
ACP host drive a multi-agent A2A graph behind a single vertical boundary.

This is the **control/progress plane** of the three orthogonal planes:

| Plane | Protocol | Role |
|---|---|---|
| Control / progress | **ACP** | host observes & steers one agent (this bridge) |
| Delegation | **A2A** | the agent fans out to sub-agents |
| Display | A2UI | rendering the result |

## How it works

`A2AAgentBridge` conforms to `ACPAgent`. On `prompt`:

1. The ACP prompt's `ContentBlock`s become an A2A `Message` (`Part`s).
2. It drives a swift-a2a `RequestHandler` via streaming send.
3. Each `StreamResponse` (artifact / message / status) maps back onto an ACP
   `session/update` reported through the client — the host's progress channel.
4. The A2A task's terminal `TaskState` becomes the prompt's `StopReason`.

```swift
let connection = InProcessConnection { client in
    A2AAgentBridge(client: client, handler: myA2ARequestHandler)
}
Task { for await update in connection.updates { render(update) } }
_ = try await connection.agent.prompt(promptRequest)
```

The `ACPA2ABridgeTests` suite proves the full three-layer flow end-to-end
(ACP host → bridge → A2A agent → streamed artifact → ACP session update),
in-process with no serialization.

Depends on `swift-acp` (`ACPCore`/`ACPAgent`/`ACPClient`) and `swift-a2a`
(`A2ACore`/`A2AServer`). Neither foundation depends on this bridge.
