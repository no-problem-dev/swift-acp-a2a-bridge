English | [日本語](./README.ja.md)

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

## Quick Start

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

## Installation

Add the package to your `Package.swift`:

```swift
.package(url: "https://github.com/no-problem-dev/swift-acp-a2a-bridge.git", from: "0.1.0"),
```

Then add `ACPA2ABridge` to your target's dependencies:

```swift
.target(
    name: "YourTarget",
    dependencies: [
        .product(name: "ACPA2ABridge", package: "swift-acp-a2a-bridge"),
    ]
)
```

## Dependencies

- [swift-acp](https://github.com/no-problem-dev/swift-acp) — `ACPCore`, `ACPAgent`, `ACPClient`
- [swift-a2a](https://github.com/no-problem-dev/swift-a2a) — `A2ACore`, `A2AServer`

Neither foundation depends on this bridge.

## License

MIT
