import Foundation
import ACPCore
import ACPAgent
import ACPClient
import A2ACore
import A2AServer

/// swift-a2a の `RequestHandler` を `ACPAgent` として提示するブリッジ。
///
/// `DefaultRequestHandler` に `AgentExecutor` を渡したものを典型的なハンドラーとして受け取り、
/// ACP ホストからは単一エージェントとして見える。背後では A2A グラフが動作できる。
///
/// `prompt` が呼ばれると、ACP プロンプトを A2A `Message` に変換してハンドラーの
/// ストリーミング送信を駆動し、各 `StreamResponse` を ACP `session/update` 通知として
/// クライアントに逐次報告する。A2A タスクの終端状態が `PromptResponse` の `StopReason` になる。
public final class A2AAgentBridge: ACPAgent {
    private let client: any ACPClient
    private let handler: any RequestHandler
    private let callContext: ServerCallContext

    /// ブリッジを生成する。
    ///
    /// - Parameters:
    ///   - client: ACP `session/update` 通知の送信先となるクライアント。
    ///   - handler: 実処理を担う swift-a2a の `RequestHandler`（通常は `AgentExecutor` を包む `DefaultRequestHandler`）。
    ///   - callContext: ハンドラーへ渡す A2A サーバー呼び出しコンテキスト。省略時は既定値を使う。
    public init(
        client: any ACPClient,
        handler: any RequestHandler,
        callContext: ServerCallContext = ServerCallContext()
    ) {
        self.client = client
        self.handler = handler
        self.callContext = callContext
    }

    /// ACP プロンプトを A2A `Message` に変換してハンドラーをストリーミング実行し、ACP 応答を返す。
    ///
    /// ストリームのイベントは ACP `session/update`（`agentMessageChunk`）として選択的に送信する。
    /// artifact と message は無条件に送信し、statusUpdate はメッセージを伴うときのみ送信する。
    /// task は終端状態の検出にのみ使い、クライアントへは送信しない。
    /// A2A タスクが終端状態に達した時点で処理を終える。終端 `TaskState` と `StopReason` の対応:
    /// `.completed` → `.endTurn`、`.canceled` → `.cancelled`、`.rejected` → `.refusal`、
    /// `.failed` → `RPCError`（`.internalError`）を投げる。
    public func prompt(_ request: PromptRequest) async throws -> PromptResponse {
        let message = Message(
            messageId: MessageID(UUID().uuidString),
            role: .user,
            parts: request.prompt.compactMap(Self.part(from:)),
            contextId: ContextID(request.sessionId.rawValue)
        )

        let stream = try await handler.onMessageSendStream(
            SendMessageRequest(message: message),
            context: callContext
        )

        var stopReason = StopReason.endTurn
        loop: for try await event in stream {
            switch event {
            case let .artifactUpdate(update):
                try await report(update.artifact.parts, to: request.sessionId)
            case let .message(message):
                try await report(message.parts, to: request.sessionId)
            case let .statusUpdate(update):
                if let message = update.status.message {
                    try await report(message.parts, to: request.sessionId)
                }
                if update.status.state.isTerminal {
                    stopReason = try Self.stopReason(for: update.status.state)
                    break loop
                }
            case let .task(task):
                if task.status.state.isTerminal {
                    stopReason = try Self.stopReason(for: task.status.state)
                    break loop
                }
            }
        }
        return PromptResponse(stopReason: stopReason)
    }

    // MARK: - Minimal session lifecycle

    /// `protocolVersion: .v1` と空の `AgentCapabilities` で応答する。
    public func initialize(_ request: InitializeRequest) async throws -> InitializeResponse {
        InitializeResponse(protocolVersion: .v1, agentCapabilities: .init())
    }

    /// UUID を新規生成してセッション ID とする。セッション状態は保持しない。
    public func newSession(_ request: NewSessionRequest) async throws -> NewSessionResponse {
        NewSessionResponse(sessionId: SessionId(UUID().uuidString))
    }

    /// ベストエフォートのキャンセル。現バージョンはノーオペレーション。
    ///
    /// 将来的には `contextId` → `taskId` を追跡してインフライトの A2A タスクをキャンセルする予定。
    /// 現時点ではストリームはハンドラーが自然に閉じた時点で終了する。
    public func cancel(_ notification: CancelNotification) async throws {}

    // MARK: - Unsupported by this bridge

    public func authenticate(_ request: AuthenticateRequest) async throws -> AuthenticateResponse {
        throw unsupported(ACPMethod.Agent.authenticate)
    }
    public func loadSession(_ request: LoadSessionRequest) async throws -> LoadSessionResponse {
        throw unsupported(ACPMethod.Agent.sessionLoad)
    }
    public func listSessions(_ request: ListSessionsRequest) async throws -> ListSessionsResponse {
        throw unsupported(ACPMethod.Agent.sessionList)
    }
    public func resumeSession(_ request: ResumeSessionRequest) async throws -> ResumeSessionResponse {
        throw unsupported(ACPMethod.Agent.sessionResume)
    }
    public func deleteSession(_ request: DeleteSessionRequest) async throws -> DeleteSessionResponse {
        throw unsupported(ACPMethod.Agent.sessionDelete)
    }
    public func closeSession(_ request: CloseSessionRequest) async throws -> CloseSessionResponse {
        throw unsupported(ACPMethod.Agent.sessionClose)
    }
    public func setSessionMode(_ request: SetSessionModeRequest) async throws -> SetSessionModeResponse {
        throw unsupported(ACPMethod.Agent.sessionSetMode)
    }
    public func setSessionConfigOption(
        _ request: SetSessionConfigOptionRequest
    ) async throws -> SetSessionConfigOptionResponse {
        throw unsupported(ACPMethod.Agent.sessionSetConfigOption)
    }
    public func logout(_ request: LogoutRequest) async throws -> LogoutResponse {
        throw unsupported(ACPMethod.Agent.logout)
    }
    public func ext(_ request: ExtRequest) async throws -> ExtResponse {
        throw unsupported(request.method)
    }
    /// ACP の拡張通知。本ブリッジでは何もせず無視する（他の未対応メソッドと異なりエラーは投げない）。
    public func extNotification(_ notification: ExtNotification) async throws {}

    private func unsupported(_ method: String) -> RPCError {
        RPCError(code: .methodNotFound, message: "A2AAgentBridge does not implement \(method)")
    }

    // MARK: - Reporting (A2A part → ACP session/update)

    private func report(_ parts: [Part], to sessionId: SessionId) async throws {
        for part in parts {
            guard let block = Self.contentBlock(from: part) else { continue }
            try await client.sessionUpdate(SessionNotification(
                sessionId: sessionId,
                update: .agentMessageChunk(ContentChunk(content: block))
            ))
        }
    }
}

// MARK: - Conversions

extension A2AAgentBridge {
    /// ACP の `ContentBlock` を A2A の `Part` に変換する。変換不可の場合は `nil` を返す。
    private static func part(from block: ContentBlock) -> Part? {
        switch block {
        case let .text(text):
            return .text(text.text)
        case let .image(image):
            return .file(
                bytes: Data(base64Encoded: image.data) ?? Data(),
                filename: nil, mediaType: image.mimeType, metadata: nil
            )
        case let .audio(audio):
            return .file(
                bytes: Data(base64Encoded: audio.data) ?? Data(),
                filename: nil, mediaType: audio.mimeType, metadata: nil
            )
        case let .resourceLink(link):
            return .file(uri: link.uri, filename: link.name, mediaType: link.mimeType, metadata: nil)
        case let .resource(resource):
            switch resource.resource {
            case let .text(text):
                return .text(text.text)
            case let .blob(blob):
                return .file(
                    bytes: Data(base64Encoded: blob.blob) ?? Data(),
                    filename: nil, mediaType: blob.mimeType, metadata: nil
                )
            }
        case .unknown:
            return nil
        }
    }

    /// A2A の `Part` を ACP の `ContentBlock`（`agent_message_chunk` 用）に変換する。変換不可の場合は `nil` を返す。
    private static func contentBlock(from part: Part) -> ContentBlock? {
        switch part.content {
        case let .text(text):
            return .text(TextContent(text: text))
        case let .uri(uri):
            return .resourceLink(ResourceLink(name: part.filename ?? uri, uri: uri, mimeType: part.mediaType))
        case let .bytes(data):
            if let mediaType = part.mediaType, mediaType.hasPrefix("image/") {
                return .image(ImageContent(data: data.base64EncodedString(), mimeType: mediaType))
            }
            return nil
        case .data:
            return nil
        }
    }

    /// A2A の終端 `TaskState` を ACP の `StopReason` に変換する。`.failed` は `RPCError` を投げる。
    private static func stopReason(for state: TaskState) throws -> StopReason {
        switch state {
        case .completed: return .endTurn
        case .canceled: return .cancelled
        case .rejected: return .refusal
        case .failed: throw RPCError(code: .internalError, message: "A2A task failed")
        default: return .endTurn
        }
    }
}
