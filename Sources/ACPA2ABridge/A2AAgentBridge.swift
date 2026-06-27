import Foundation
import ACPCore
import ACPAgent
import ACPClient
import A2ACore
import A2AServer

/// Presents a swift-a2a agent (any `RequestHandler`, typically a
/// `DefaultRequestHandler` wrapping an `AgentExecutor`) as an `ACPAgent`.
///
/// On `prompt`, the bridge converts the ACP prompt into an A2A `Message`, drives
/// the handler's streaming send, and maps each `StreamResponse` back onto an ACP
/// `session/update` notification reported through the client. The A2A task's
/// terminal state becomes the prompt's `StopReason`. This is the vertical
/// ACP boundary over an A2A core — the host sees one agent; behind it an A2A
/// graph may run.
public final class A2AAgentBridge: ACPAgent {
    private let client: any ACPClient
    private let handler: any RequestHandler
    private let callContext: ServerCallContext

    public init(
        client: any ACPClient,
        handler: any RequestHandler,
        callContext: ServerCallContext = ServerCallContext()
    ) {
        self.client = client
        self.handler = handler
        self.callContext = callContext
    }

    /// Converts an ACP prompt into an A2A `Message`, streams the handler's response,
    /// and maps each `StreamResponse` back onto the ACP `session/update` channel via
    /// the client. Returns when the A2A task reaches a terminal state; the terminal
    /// `TaskState` determines the `StopReason` (`.endTurn` for completed, `.cancelled`
    /// for canceled, `.refusal` for rejected, error for failed).
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

    /// Returns `protocolVersion: .v1` with an empty capability set.
    public func initialize(_ request: InitializeRequest) async throws -> InitializeResponse {
        InitializeResponse(protocolVersion: .v1, agentCapabilities: .init())
    }

    /// Creates a new session backed by a UUID; session state is not persisted.
    public func newSession(_ request: NewSessionRequest) async throws -> NewSessionResponse {
        NewSessionResponse(sessionId: SessionId(UUID().uuidString))
    }

    /// Best-effort cancellation: a future revision will track `contextId→taskId` to
    /// cancel the in-flight A2A task. For now the streamed turn ends when the
    /// handler closes naturally.
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
    /// ACP prompt content → A2A message part.
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

    /// A2A streamed part → ACP content block (for an `agent_message_chunk`).
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

    /// A2A terminal task state → ACP stop reason. `.failed` surfaces as an error.
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
