[English](./README.md) | 日本語

# swift-acp-a2a-bridge

[swift-a2a](https://github.com/no-problem-dev/swift-a2a) エージェントを
[ACP](https://agentclientprotocol.com) エージェントとして公開するブリッジ。
ACP ホストが単一の垂直境界を通してマルチエージェント A2A グラフを制御するための接続層。

このパッケージは 3 つの直交する平面のうち**制御/進捗平面**を担う:

| 平面 | プロトコル | 役割 |
|---|---|---|
| 制御 / 進捗 | **ACP** | ホストが 1 つのエージェント（このブリッジ）を観察・制御する |
| 委譲 | **A2A** | エージェントがサブエージェントにファンアウトする |
| 表示 | A2UI | 結果をレンダリングする |

## 仕組み

`A2AAgentBridge` は `ACPAgent` に準拠する。`prompt` が呼ばれると:

1. ACP プロンプトの `ContentBlock` が A2A の `Message`（`Part` のリスト）に変換される。
2. swift-a2a の `RequestHandler` のストリーミング送信を駆動する。
3. 各 `StreamResponse`（artifact / message / status）が ACP `session/update` 通知として
   クライアントに報告される — ホストの進捗チャンネル。
4. A2A タスクの終端 `TaskState` がプロンプトの `StopReason` になる。

## クイックスタート

```swift
let connection = InProcessConnection { client in
    A2AAgentBridge(client: client, handler: myA2ARequestHandler)
}
Task { for await update in connection.updates { render(update) } }
_ = try await connection.agent.prompt(promptRequest)
```

`ACPA2ABridgeTests` スイートが ACP ホスト → ブリッジ → A2A エージェント → ストリーミングアーティファクト → ACP セッション更新という 3 層フロー全体をインプロセスで検証している。

## インストール

`Package.swift` にパッケージを追加する:

```swift
.package(url: "https://github.com/no-problem-dev/swift-acp-a2a-bridge.git", from: "0.1.0"),
```

ターゲットの依存関係に `ACPA2ABridge` を追加する:

```swift
.target(
    name: "YourTarget",
    dependencies: [
        .product(name: "ACPA2ABridge", package: "swift-acp-a2a-bridge"),
    ]
)
```

## 依存関係

- [swift-acp](https://github.com/no-problem-dev/swift-acp) — `ACPCore`、`ACPAgent`、`ACPClient`
- [swift-a2a](https://github.com/no-problem-dev/swift-a2a) — `A2ACore`、`A2AServer`

どちらの基盤パッケージもこのブリッジに依存しない。

## ライセンス

MIT
