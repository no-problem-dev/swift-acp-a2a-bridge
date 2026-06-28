# ``ACPA2ABridge``

swift-a2a エージェントを ACP エージェントとして公開するブリッジモジュール。

## Overview

`ACPA2ABridge` は ACP（Agent Communication Protocol）と A2A（Agent-to-Agent）プロトコルを接続するアダプター層。
`A2AAgentBridge` を使うだけで、任意の `RequestHandler`（通常は `DefaultRequestHandler` に `AgentExecutor` を渡したもの）を ACP ホストに `ACPAgent` として提示できる。

ブリッジは次の変換を担う。

- **ACP → A2A**: ACP の `PromptRequest`（`ContentBlock` のリスト）を A2A の `Message` に変換し、
  ハンドラーの `onMessageSendStream` を呼び出す。
- **A2A → ACP**: ハンドラーが返す `StreamResponse` を ACP の `session/update` 通知（`agentMessageChunk`）に
  マップして送信する。artifact と message は無条件、statusUpdate はメッセージを伴うときのみ送信し、task は終端検出にのみ使う。
- **終了**: A2A タスクの終端状態（`completed` / `canceled` / `rejected` / `failed`）を
  ACP の `StopReason` に変換して `PromptResponse` を返す。

### 基本的な使い方

```swift
import ACPA2ABridge
import A2AServer
import ACPAgent

// 1. A2A ハンドラーを用意（AgentExecutor を実装したものを渡す）
let card = AgentCard(
    name: "MyAgent",
    description: "My A2A agent.",
    supportedInterfaces: [AgentInterface(url: "acp://local", protocolBinding: "JSONRPC")],
    version: "1.0",
    capabilities: AgentCapabilities(streaming: true)
)
let handler = DefaultRequestHandler(agentCard: card, executor: MyAgentExecutor())

// 2. ACP クライアントと組み合わせてブリッジを作成
let bridge = A2AAgentBridge(client: acpClient, handler: handler)

// 3. ACP ホストに渡すだけ — ホスト側は A2A の存在を意識しない
let response = try await bridge.prompt(
    PromptRequest(sessionId: "session-1", prompt: [.text(TextContent(text: "こんにちは"))])
)
print(response.stopReason) // .endTurn
```

セッション管理（`initialize`・`newSession`・`cancel`）はブリッジが最小実装で提供する。
`authenticate`・`loadSession` など本ブリッジが対応しないメソッドは `.methodNotFound` エラーを返す。

## Topics

### ブリッジ

- ``A2AAgentBridge``
