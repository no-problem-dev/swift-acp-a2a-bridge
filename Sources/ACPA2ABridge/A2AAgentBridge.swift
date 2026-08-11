import Foundation
import ACPCore
import ACPAgent
import ACPClient
import A2ACore
import A2AServer

/// A bridge that presents a swift-a2a `RequestHandler` as an `ACPAgent`.
///
/// The typical handler it takes is a `DefaultRequestHandler` given an `AgentExecutor`. To an ACP
/// host it looks like a single agent, while an A2A graph can be running behind it.
///
/// When `prompt` is called, it converts the ACP prompt into an A2A `Message`, drives the handler's
/// streaming send, and reports each `StreamResponse` to the client as it arrives, as an ACP
/// `session/update` notification. The terminal state of the A2A task becomes the `StopReason` of
/// the `PromptResponse`.
public final class A2AAgentBridge: ACPAgent {
    private let client: any ACPClient
    private let handler: any RequestHandler
    private let callContext: ServerCallContext

    /// Creates the bridge.
    ///
    /// - Parameters:
    ///   - client: The client that ACP `session/update` notifications are sent to.
    ///   - handler: The swift-a2a `RequestHandler` that does the actual work (usually a
    ///     `DefaultRequestHandler` wrapping an `AgentExecutor`).
    ///   - callContext: The A2A server call context handed to the handler. Omitted, it uses the default.
    public init(
        client: any ACPClient,
        handler: any RequestHandler,
        callContext: ServerCallContext = ServerCallContext()
    ) {
        self.client = client
        self.handler = handler
        self.callContext = callContext
    }

    /// Converts the ACP prompt into an A2A `Message`, runs the handler as a stream, and returns the
    /// ACP response.
    ///
    /// Stream events are sent selectively as ACP `session/update` (`agentMessageChunk`). Artifacts
    /// and messages are sent unconditionally; a statusUpdate is sent only when it carries a message.
    /// A task is used only to detect the terminal state and is never sent to the client.
    /// Processing ends the moment the A2A task reaches a terminal state. Terminal `TaskState` maps
    /// to `StopReason` as: `.completed` → `.endTurn`, `.canceled` → `.cancelled`,
    /// `.rejected` → `.refusal`, and `.failed` → throws an `RPCError` (`.internalError`).
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

    /// Responds with `protocolVersion: .v1` and an empty `AgentCapabilities`.
    public func initialize(_ request: InitializeRequest) async throws -> InitializeResponse {
        InitializeResponse(protocolVersion: .v1, agentCapabilities: .init())
    }

    /// Generates a fresh UUID and uses it as the session ID. No session state is kept.
    public func newSession(_ request: NewSessionRequest) async throws -> NewSessionResponse {
        NewSessionResponse(sessionId: SessionId(UUID().uuidString))
    }

    /// Best-effort cancellation. In the current version this is a no-op.
    ///
    /// The plan is to track `contextId` → `taskId` and cancel the in-flight A2A task. For now the
    /// stream ends when the handler closes it on its own.
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
    /// An ACP extension notification. This bridge does nothing and ignores it (unlike the other
    /// unsupported methods, it does not throw).
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
    /// Converts an ACP `ContentBlock` into an A2A `Part`. Returns `nil` when it cannot be converted.
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

    /// Converts an A2A `Part` into an ACP `ContentBlock` (for `agent_message_chunk`). Returns `nil`
    /// when it cannot be converted.
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

    /// Converts a terminal A2A `TaskState` into an ACP `StopReason`. `.failed` throws an `RPCError`.
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
