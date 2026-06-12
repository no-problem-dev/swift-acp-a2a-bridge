import Foundation
import Testing
import ACPCore
import ACPTransport
import A2ACore
import A2AServer
@testable import ACPA2ABridge

/// A minimal A2A agent that echoes the user's input back as an artifact.
private struct EchoExecutor: AgentExecutor {
    func execute(_ context: RequestContext, eventQueue: EventQueue) async throws {
        let updater = TaskUpdater(eventQueue: eventQueue, taskId: context.taskId, contextId: context.contextId)
        try await updater.submit()
        try await updater.startWork()
        await updater.addArtifact([.text("echo: \(context.getUserInput())")], name: "echo")
        try await updater.complete()
    }

    func cancel(_ context: RequestContext, eventQueue: EventQueue) async throws {
        let updater = TaskUpdater(eventQueue: eventQueue, taskId: context.taskId, contextId: context.contextId)
        try await updater.cancel()
    }
}

@Suite("ACP⇄A2A bridge")
struct BridgeTests {
    private func makeHandler() -> DefaultRequestHandler {
        let card = AgentCard(
            name: "Echo",
            description: "Echoes the user's input.",
            supportedInterfaces: [AgentInterface(url: "acp://local", protocolBinding: "JSONRPC")],
            version: "1.0",
            capabilities: A2ACore.AgentCapabilities(streaming: true)
        )
        return DefaultRequestHandler(agentCard: card, executor: EchoExecutor())
    }

    /// Full three-layer flow: an ACP host drives the bridge (an `ACPAgent`),
    /// which runs an A2A agent and maps its streamed artifacts back onto the ACP
    /// `session/update` channel the host observes — all in-process.
    @Test func a2aAgentDrivesAcpSessionUpdates() async throws {
        let handler = makeHandler()
        let connection = InProcessConnection { client in
            A2AAgentBridge(client: client, handler: handler)
        }

        let collector = Task {
            var texts: [String] = []
            for await update in connection.updates {
                if case let .agentMessageChunk(chunk) = update.update,
                   case let .text(text) = chunk.content {
                    texts.append(text.text)
                }
            }
            return texts
        }

        let response = try await connection.agent.prompt(
            PromptRequest(sessionId: "s1", prompt: [.text(TextContent(text: "hello"))])
        )
        connection.finish()

        #expect(response.stopReason == .endTurn)
        let texts = await collector.value
        #expect(texts.contains("echo: hello"))
    }
}
