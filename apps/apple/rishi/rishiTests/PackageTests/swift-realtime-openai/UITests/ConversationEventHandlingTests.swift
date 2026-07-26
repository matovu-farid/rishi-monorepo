@testable import rishi
import Testing



@Suite("Conversation event handling")
@MainActor
struct ConversationEventHandlingTests {

    @Test("response.output_item.added appends a function call entry")
    func responseOutputItemAddedAppendsEntry() throws {
        let conversation = Conversation(debug: false)
        let item = Item.functionCall(.init(
            id: "item-1",
            status: .inProgress,
            callId: "call-1",
            name: "bookContext",
            arguments: ""
        ))

        try conversation.ingestForTesting(
            .responseOutputItemAdded(
                eventId: "event-1",
                responseId: "response-1",
                outputIndex: 0,
                item: item
            )
        )

        #expect(conversation.entries.count == 1)
        guard case let .functionCall(functionCall) = conversation.entries[0] else {
            Issue.record("Expected a function call entry")
            return
        }
        #expect(functionCall.callId == "call-1")
        #expect(functionCall.name == "bookContext")
        #expect(functionCall.status == .inProgress)
    }

    @Test("response.output_item.done updates the existing function call entry")
    func responseOutputItemDoneUpdatesEntry() throws {
        let conversation = Conversation(debug: false)
        let added = Item.functionCall(.init(
            id: "item-1",
            status: .inProgress,
            callId: "call-1",
            name: "bookContext",
            arguments: ""
        ))
        let done = Item.functionCall(.init(
            id: "item-1",
            status: .completed,
            callId: "call-1",
            name: "bookContext",
            arguments: "{\"queryText\":\"chapter 4\"}"
        ))

        try conversation.ingestForTesting(
            .responseOutputItemAdded(
                eventId: "event-1",
                responseId: "response-1",
                outputIndex: 0,
                item: added
            )
        )
        try conversation.ingestForTesting(
            .responseOutputItemDone(
                eventId: "event-2",
                responseId: "response-1",
                outputIndex: 0,
                item: done
            )
        )

        #expect(conversation.entries.count == 1)
        guard case let .functionCall(functionCall) = conversation.entries[0] else {
            Issue.record("Expected a function call entry")
            return
        }
        #expect(functionCall.status == .completed)
        #expect(functionCall.arguments == "{\"queryText\":\"chapter 4\"}")
    }
}
