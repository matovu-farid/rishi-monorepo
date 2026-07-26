import Foundation

public enum ServerEvent: Codable, Sendable {
	public struct RateLimit: Equatable, Hashable, Codable, Sendable {
		public let name: String
		public let limit: Int
		public let remaining: Int
		public let resetSeconds: Double
	}

	public struct LogProb: Equatable, Hashable, Codable, Sendable {
		public var bytes: [Int]
		public var logprob: Double
		public var token: String
	}

	case error(eventId: String, error: ServerError)
	case sessionCreated(eventId: String, session: RealtimeSession)
	case sessionUpdated(eventId: String, session: RealtimeSession)
	case conversationItemCreated(eventId: String, item: Item, previousItemId: String?)
	case conversationItemAdded(eventId: String, item: Item, previousItemId: String?)
	case conversationItemDone(eventId: String, item: Item, previousItemId: String?)
	case conversationItemRetrieved(eventId: String, item: Item)
	case conversationItemInputAudioTranscriptionCompleted(eventId: String, itemId: String, contentIndex: Int, transcript: String, logprobs: [LogProb]?, usage: Response.Usage)
	case conversationItemInputAudioTranscriptionDelta(eventId: String, itemId: String, contentIndex: Int, delta: String, logprobs: [LogProb]?)
	case conversationItemInputAudioTranscriptionSegment(eventId: String, itemId: String, contentIndex: Int, id: String, speaker: String, text: String, start: Double, end: Double)
	case conversationItemInputAudioTranscriptionFailed(eventId: String, itemId: String, contentIndex: Int, error: ServerError)
	case conversationItemTruncated(eventId: String, itemId: String, contentIndex: Int, audioEndMs: Int)
	case conversationItemDeleted(eventId: String, itemId: String)
	case inputAudioBufferCommitted(eventId: String, itemId: String, previousItemId: String?)
	case inputAudioBufferCleared(eventId: String)
	case inputAudioBufferSpeechStarted(eventId: String, itemId: String, audioStartMs: Int)
	case inputAudioBufferSpeechStopped(eventId: String, itemId: String, audioEndMs: Int)
	case inputAudioBufferTimeoutTriggered(eventId: String, itemId: String, audioStartMs: Int, audioEndMs: Int)
	case outputAudioBufferStarted(eventId: String, responseId: String)
	case outputAudioBufferStopped(eventId: String, responseId: String)
	case responseCreated(eventId: String, response: Response)
	case responseDone(eventId: String, response: Response)
	case responseOutputItemAdded(eventId: String, responseId: String, outputIndex: Int, item: Item)
	case responseOutputItemDone(eventId: String, responseId: String, outputIndex: Int, item: Item)
	case responseContentPartAdded(eventId: String, responseId: String, itemId: String, outputIndex: Int, contentIndex: Int, part: Item.ContentPart)
	case responseContentPartDone(eventId: String, responseId: String, itemId: String, outputIndex: Int, contentIndex: Int, part: Item.ContentPart)
	case responseTextDelta(eventId: String, responseId: String, itemId: String, outputIndex: Int, contentIndex: Int, delta: String)
	case responseTextDone(eventId: String, responseId: String, itemId: String, outputIndex: Int, contentIndex: Int, text: String)
	case responseAudioTranscriptDelta(eventId: String, responseId: String, itemId: String, outputIndex: Int, contentIndex: Int, delta: String)
	case responseAudioTranscriptDone(eventId: String, responseId: String, itemId: String, outputIndex: Int, contentIndex: Int, transcript: String)
	case responseOutputAudioDelta(eventId: String, responseId: String, itemId: String, outputIndex: Int, contentIndex: Int, delta: AudioData)
	case responseOutputAudioDone(eventId: String, responseId: String, itemId: String, outputIndex: Int, contentIndex: Int)
	case responseFunctionCallArgumentsDelta(eventId: String, responseId: String, itemId: String, outputIndex: Int, callId: String, delta: String)
	case responseFunctionCallArgumentsDone(eventId: String, responseId: String, itemId: String, outputIndex: Int, callId: String, arguments: String)
	case responseMCPCallArgumentsDelta(eventId: String, responseId: String, itemId: String, outputIndex: Int, delta: String, obfuscation: String?)
	case responseMCPCallArgumentsDone(eventId: String, responseId: String, itemId: String, outputIndex: Int, arguments: String)
	case mcpListToolsInProgress(eventId: String, itemId: String)
	case mcpListToolsCompleted(eventId: String, itemId: String)
	case mcpListToolsFailed(eventId: String, itemId: String)
	case responseMCPCallInProgress(eventId: String, itemId: String, outputIndex: Int)
	case responseMCPCallCompleted(eventId: String, itemId: String, outputIndex: Int)
	case responseMCPCallFailed(eventId: String, itemId: String, outputIndex: Int)
	case rateLimitsUpdated(eventId: String, rateLimits: [RateLimit])
}

extension ServerEvent: Identifiable {
	public var id: String {
		switch self {
			case let .error(id, _): id
			case let .sessionCreated(id, _): id
			case let .sessionUpdated(id, _): id
			case let .conversationItemAdded(id, _, _): id
			case let .conversationItemCreated(id, _, _): id
			case let .conversationItemDone(id, _, _): id
			case let .conversationItemRetrieved(id, _): id
			case let .conversationItemInputAudioTranscriptionCompleted(id, _, _, _, _, _): id
			case let .conversationItemInputAudioTranscriptionDelta(id, _, _, _, _): id
			case let .conversationItemInputAudioTranscriptionSegment(id, _, _, _, _, _, _, _): id
			case let .conversationItemInputAudioTranscriptionFailed(id, _, _, _): id
			case let .conversationItemTruncated(id, _, _, _): id
			case let .conversationItemDeleted(id, _): id
			case let .inputAudioBufferCommitted(id, _, _): id
			case let .inputAudioBufferCleared(id): id
			case let .inputAudioBufferSpeechStarted(id, _, _): id
			case let .inputAudioBufferSpeechStopped(id, _, _): id
			case let .inputAudioBufferTimeoutTriggered(id, _, _, _): id
			case let .outputAudioBufferStarted(id, _): id
			case let .outputAudioBufferStopped(id, _): id
			case let .responseCreated(id, _): id
			case let .responseDone(id, _): id
			case let .responseOutputItemAdded(id, _, _, _): id
			case let .responseOutputItemDone(id, _, _, _): id
			case let .responseContentPartAdded(id, _, _, _, _, _): id
			case let .responseContentPartDone(id, _, _, _, _, _): id
			case let .responseTextDelta(id, _, _, _, _, _): id
			case let .responseTextDone(id, _, _, _, _, _): id
			case let .responseAudioTranscriptDelta(id, _, _, _, _, _): id
			case let .responseAudioTranscriptDone(id, _, _, _, _, _): id
			case let .responseOutputAudioDelta(id, _, _, _, _, _): id
			case let .responseOutputAudioDone(id, _, _, _, _): id
			case let .responseFunctionCallArgumentsDelta(id, _, _, _, _, _): id
			case let .responseFunctionCallArgumentsDone(id, _, _, _, _, _): id
			case let .responseMCPCallArgumentsDelta(id, _, _, _, _, _): id
			case let .responseMCPCallArgumentsDone(id, _, _, _, _): id
			case let .mcpListToolsInProgress(id, _): id
			case let .mcpListToolsCompleted(id, _): id
			case let .mcpListToolsFailed(id, _): id
			case let .responseMCPCallInProgress(id, _, _): id
			case let .responseMCPCallCompleted(id, _, _): id
			case let .responseMCPCallFailed(id, _, _): id
			case let .rateLimitsUpdated(id, _): id
		}
	}
}

extension ServerEvent {
	private enum CodingKeys: String, CodingKey {
		case type
		case eventId
		case error
		case session
		case item
		case previousItemId
		case itemId
		case contentIndex
		case transcript
		case logprobs
		case usage
		case delta
		case id
		case speaker
		case text
		case start
		case end
		case audioEndMs
		case audioStartMs
		case responseId
		case response
		case outputIndex
		case part
		case callId
		case arguments
		case obfuscation
		case rateLimits
	}

	public func encode(to encoder: any Encoder) throws {
		var container = encoder.container(keyedBy: CodingKeys.self)

		switch self {
			case let .error(eventId, error):
				try container.encode("error", forKey: .type)
				try container.encode(eventId, forKey: .eventId)
				try container.encode(error, forKey: .error)
			case let .sessionCreated(eventId, session):
				try container.encode("session.created", forKey: .type)
				try container.encode(eventId, forKey: .eventId)
				try container.encode(session, forKey: .session)
			case let .sessionUpdated(eventId, session):
				try container.encode("session.updated", forKey: .type)
				try container.encode(eventId, forKey: .eventId)
				try container.encode(session, forKey: .session)
			case let .conversationItemCreated(eventId, item, previousItemId):
				try container.encode("conversation.item.created", forKey: .type)
				try container.encode(eventId, forKey: .eventId)
				try container.encode(item, forKey: .item)
				try container.encodeIfPresent(previousItemId, forKey: .previousItemId)
			case let .conversationItemAdded(eventId, item, previousItemId):
				try container.encode("conversation.item.added", forKey: .type)
				try container.encode(eventId, forKey: .eventId)
				try container.encode(item, forKey: .item)
				try container.encodeIfPresent(previousItemId, forKey: .previousItemId)
			case let .conversationItemDone(eventId, item, previousItemId):
				try container.encode("conversation.item.done", forKey: .type)
				try container.encode(eventId, forKey: .eventId)
				try container.encode(item, forKey: .item)
				try container.encodeIfPresent(previousItemId, forKey: .previousItemId)
			case let .conversationItemRetrieved(eventId, item):
				try container.encode("conversation.item.retrieved", forKey: .type)
				try container.encode(eventId, forKey: .eventId)
				try container.encode(item, forKey: .item)
			case let .conversationItemInputAudioTranscriptionCompleted(eventId, itemId, contentIndex, transcript, logprobs, usage):
				try container.encode("conversation.item.input_audio_transcription.completed", forKey: .type)
				try container.encode(eventId, forKey: .eventId)
				try container.encode(itemId, forKey: .itemId)
				try container.encode(contentIndex, forKey: .contentIndex)
				try container.encode(transcript, forKey: .transcript)
				try container.encodeIfPresent(logprobs, forKey: .logprobs)
				try container.encode(usage, forKey: .usage)
			case let .conversationItemInputAudioTranscriptionDelta(eventId, itemId, contentIndex, delta, logprobs):
				try container.encode("conversation.item.input_audio_transcription.delta", forKey: .type)
				try container.encode(eventId, forKey: .eventId)
				try container.encode(itemId, forKey: .itemId)
				try container.encode(contentIndex, forKey: .contentIndex)
				try container.encode(delta, forKey: .delta)
				try container.encodeIfPresent(logprobs, forKey: .logprobs)
			case let .conversationItemInputAudioTranscriptionSegment(eventId, itemId, contentIndex, id, speaker, text, start, end):
				try container.encode("conversation.item.input_audio_transcription.segment", forKey: .type)
				try container.encode(eventId, forKey: .eventId)
				try container.encode(itemId, forKey: .itemId)
				try container.encode(contentIndex, forKey: .contentIndex)
				try container.encode(id, forKey: .id)
				try container.encode(speaker, forKey: .speaker)
				try container.encode(text, forKey: .text)
				try container.encode(start, forKey: .start)
				try container.encode(end, forKey: .end)
			case let .conversationItemInputAudioTranscriptionFailed(eventId, itemId, contentIndex, error):
				try container.encode("conversation.item.input_audio_transcription.failed", forKey: .type)
				try container.encode(eventId, forKey: .eventId)
				try container.encode(itemId, forKey: .itemId)
				try container.encode(contentIndex, forKey: .contentIndex)
				try container.encode(error, forKey: .error)
			case let .conversationItemTruncated(eventId, itemId, contentIndex, audioEndMs):
				try container.encode("conversation.item.truncated", forKey: .type)
				try container.encode(eventId, forKey: .eventId)
				try container.encode(itemId, forKey: .itemId)
				try container.encode(contentIndex, forKey: .contentIndex)
				try container.encode(audioEndMs, forKey: .audioEndMs)
			case let .conversationItemDeleted(eventId, itemId):
				try container.encode("conversation.item.deleted", forKey: .type)
				try container.encode(eventId, forKey: .eventId)
				try container.encode(itemId, forKey: .itemId)
			case let .inputAudioBufferCommitted(eventId, itemId, previousItemId):
				try container.encode("input_audio_buffer.committed", forKey: .type)
				try container.encode(eventId, forKey: .eventId)
				try container.encode(itemId, forKey: .itemId)
				try container.encodeIfPresent(previousItemId, forKey: .previousItemId)
			case let .inputAudioBufferCleared(eventId):
				try container.encode("input_audio_buffer.cleared", forKey: .type)
				try container.encode(eventId, forKey: .eventId)
			case let .inputAudioBufferSpeechStarted(eventId, itemId, audioStartMs):
				try container.encode("input_audio_buffer.speech_started", forKey: .type)
				try container.encode(eventId, forKey: .eventId)
				try container.encode(itemId, forKey: .itemId)
				try container.encode(audioStartMs, forKey: .audioStartMs)
			case let .inputAudioBufferSpeechStopped(eventId, itemId, audioEndMs):
				try container.encode("input_audio_buffer.speech_stopped", forKey: .type)
				try container.encode(eventId, forKey: .eventId)
				try container.encode(itemId, forKey: .itemId)
				try container.encode(audioEndMs, forKey: .audioEndMs)
			case let .inputAudioBufferTimeoutTriggered(eventId, itemId, audioStartMs, audioEndMs):
				try container.encode("input_audio_buffer.timeout_triggered", forKey: .type)
				try container.encode(eventId, forKey: .eventId)
				try container.encode(itemId, forKey: .itemId)
				try container.encode(audioStartMs, forKey: .audioStartMs)
				try container.encode(audioEndMs, forKey: .audioEndMs)
			case let .outputAudioBufferStarted(eventId, responseId):
				try container.encode("output_audio_buffer.started", forKey: .type)
				try container.encode(eventId, forKey: .eventId)
				try container.encode(responseId, forKey: .responseId)
			case let .outputAudioBufferStopped(eventId, responseId):
				try container.encode("output_audio_buffer.stopped", forKey: .type)
				try container.encode(eventId, forKey: .eventId)
				try container.encode(responseId, forKey: .responseId)
			case let .responseCreated(eventId, response):
				try container.encode("response.created", forKey: .type)
				try container.encode(eventId, forKey: .eventId)
				try container.encode(response, forKey: .response)
			case let .responseDone(eventId, response):
				try container.encode("response.done", forKey: .type)
				try container.encode(eventId, forKey: .eventId)
				try container.encode(response, forKey: .response)
			case let .responseOutputItemAdded(eventId, responseId, outputIndex, item):
				try container.encode("response.output_item.added", forKey: .type)
				try container.encode(eventId, forKey: .eventId)
				try container.encode(responseId, forKey: .responseId)
				try container.encode(outputIndex, forKey: .outputIndex)
				try container.encode(item, forKey: .item)
			case let .responseOutputItemDone(eventId, responseId, outputIndex, item):
				try container.encode("response.output_item.done", forKey: .type)
				try container.encode(eventId, forKey: .eventId)
				try container.encode(responseId, forKey: .responseId)
				try container.encode(outputIndex, forKey: .outputIndex)
				try container.encode(item, forKey: .item)
			case let .responseContentPartAdded(eventId, responseId, itemId, outputIndex, contentIndex, part):
				try container.encode("response.content_part.added", forKey: .type)
				try container.encode(eventId, forKey: .eventId)
				try container.encode(responseId, forKey: .responseId)
				try container.encode(itemId, forKey: .itemId)
				try container.encode(outputIndex, forKey: .outputIndex)
				try container.encode(contentIndex, forKey: .contentIndex)
				try container.encode(part, forKey: .part)
			case let .responseContentPartDone(eventId, responseId, itemId, outputIndex, contentIndex, part):
				try container.encode("response.content_part.done", forKey: .type)
				try container.encode(eventId, forKey: .eventId)
				try container.encode(responseId, forKey: .responseId)
				try container.encode(itemId, forKey: .itemId)
				try container.encode(outputIndex, forKey: .outputIndex)
				try container.encode(contentIndex, forKey: .contentIndex)
				try container.encode(part, forKey: .part)
			case let .responseTextDelta(eventId, responseId, itemId, outputIndex, contentIndex, delta):
				try container.encode("response.text.delta", forKey: .type)
				try container.encode(eventId, forKey: .eventId)
				try container.encode(responseId, forKey: .responseId)
				try container.encode(itemId, forKey: .itemId)
				try container.encode(outputIndex, forKey: .outputIndex)
				try container.encode(contentIndex, forKey: .contentIndex)
				try container.encode(delta, forKey: .delta)
			case let .responseTextDone(eventId, responseId, itemId, outputIndex, contentIndex, text):
				try container.encode("response.text.done", forKey: .type)
				try container.encode(eventId, forKey: .eventId)
				try container.encode(responseId, forKey: .responseId)
				try container.encode(itemId, forKey: .itemId)
				try container.encode(outputIndex, forKey: .outputIndex)
				try container.encode(contentIndex, forKey: .contentIndex)
				try container.encode(text, forKey: .text)
			case let .responseAudioTranscriptDelta(eventId, responseId, itemId, outputIndex, contentIndex, delta):
				try container.encode("response.output_audio_transcript.delta", forKey: .type)
				try container.encode(eventId, forKey: .eventId)
				try container.encode(responseId, forKey: .responseId)
				try container.encode(itemId, forKey: .itemId)
				try container.encode(outputIndex, forKey: .outputIndex)
				try container.encode(contentIndex, forKey: .contentIndex)
				try container.encode(delta, forKey: .delta)
			case let .responseAudioTranscriptDone(eventId, responseId, itemId, outputIndex, contentIndex, transcript):
				try container.encode("response.output_audio_transcript.done", forKey: .type)
				try container.encode(eventId, forKey: .eventId)
				try container.encode(responseId, forKey: .responseId)
				try container.encode(itemId, forKey: .itemId)
				try container.encode(outputIndex, forKey: .outputIndex)
				try container.encode(contentIndex, forKey: .contentIndex)
				try container.encode(transcript, forKey: .transcript)
			case let .responseOutputAudioDelta(eventId, responseId, itemId, outputIndex, contentIndex, delta):
				try container.encode("response.output_audio.delta", forKey: .type)
				try container.encode(eventId, forKey: .eventId)
				try container.encode(responseId, forKey: .responseId)
				try container.encode(itemId, forKey: .itemId)
				try container.encode(outputIndex, forKey: .outputIndex)
				try container.encode(contentIndex, forKey: .contentIndex)
				try container.encode(delta, forKey: .delta)
			case let .responseOutputAudioDone(eventId, responseId, itemId, outputIndex, contentIndex):
				try container.encode("response.output_audio.done", forKey: .type)
				try container.encode(eventId, forKey: .eventId)
				try container.encode(responseId, forKey: .responseId)
				try container.encode(itemId, forKey: .itemId)
				try container.encode(outputIndex, forKey: .outputIndex)
				try container.encode(contentIndex, forKey: .contentIndex)
			case let .responseFunctionCallArgumentsDelta(eventId, responseId, itemId, outputIndex, callId, delta):
				try container.encode("response.function_call_arguments.delta", forKey: .type)
				try container.encode(eventId, forKey: .eventId)
				try container.encode(responseId, forKey: .responseId)
				try container.encode(itemId, forKey: .itemId)
				try container.encode(outputIndex, forKey: .outputIndex)
				try container.encode(callId, forKey: .callId)
				try container.encode(delta, forKey: .delta)
			case let .responseFunctionCallArgumentsDone(eventId, responseId, itemId, outputIndex, callId, arguments):
				try container.encode("response.function_call_arguments.done", forKey: .type)
				try container.encode(eventId, forKey: .eventId)
				try container.encode(responseId, forKey: .responseId)
				try container.encode(itemId, forKey: .itemId)
				try container.encode(outputIndex, forKey: .outputIndex)
				try container.encode(callId, forKey: .callId)
				try container.encode(arguments, forKey: .arguments)
			case let .responseMCPCallArgumentsDelta(eventId, responseId, itemId, outputIndex, delta, obfuscation):
				try container.encode("response.mcp_call_arguments.delta", forKey: .type)
				try container.encode(eventId, forKey: .eventId)
				try container.encode(responseId, forKey: .responseId)
				try container.encode(itemId, forKey: .itemId)
				try container.encode(outputIndex, forKey: .outputIndex)
				try container.encode(delta, forKey: .delta)
				try container.encodeIfPresent(obfuscation, forKey: .obfuscation)
			case let .responseMCPCallArgumentsDone(eventId, responseId, itemId, outputIndex, arguments):
				try container.encode("response.mcp_call_arguments.done", forKey: .type)
				try container.encode(eventId, forKey: .eventId)
				try container.encode(responseId, forKey: .responseId)
				try container.encode(itemId, forKey: .itemId)
				try container.encode(outputIndex, forKey: .outputIndex)
				try container.encode(arguments, forKey: .arguments)
			case let .mcpListToolsInProgress(eventId, itemId):
				try container.encode("mcp_list_tools.in_progress", forKey: .type)
				try container.encode(eventId, forKey: .eventId)
				try container.encode(itemId, forKey: .itemId)
			case let .mcpListToolsCompleted(eventId, itemId):
				try container.encode("mcp_list_tools.completed", forKey: .type)
				try container.encode(eventId, forKey: .eventId)
				try container.encode(itemId, forKey: .itemId)
			case let .mcpListToolsFailed(eventId, itemId):
				try container.encode("mcp_list_tools.failed", forKey: .type)
				try container.encode(eventId, forKey: .eventId)
				try container.encode(itemId, forKey: .itemId)
			case let .responseMCPCallInProgress(eventId, itemId, outputIndex):
				try container.encode("response.mcp_call.in_progress", forKey: .type)
				try container.encode(eventId, forKey: .eventId)
				try container.encode(itemId, forKey: .itemId)
				try container.encode(outputIndex, forKey: .outputIndex)
			case let .responseMCPCallCompleted(eventId, itemId, outputIndex):
				try container.encode("response.mcp_call.completed", forKey: .type)
				try container.encode(eventId, forKey: .eventId)
				try container.encode(itemId, forKey: .itemId)
				try container.encode(outputIndex, forKey: .outputIndex)
			case let .responseMCPCallFailed(eventId, itemId, outputIndex):
				try container.encode("response.mcp_call.failed", forKey: .type)
				try container.encode(eventId, forKey: .eventId)
				try container.encode(itemId, forKey: .itemId)
				try container.encode(outputIndex, forKey: .outputIndex)
			case let .rateLimitsUpdated(eventId, rateLimits):
				try container.encode("rate_limits.updated", forKey: .type)
				try container.encode(eventId, forKey: .eventId)
				try container.encode(rateLimits, forKey: .rateLimits)
		}
	}

	public init(from decoder: any Decoder) throws {
		let container = try decoder.container(keyedBy: CodingKeys.self)
		let type = try container.decode(String.self, forKey: .type)

		switch type {
			case "error":
				self = .error(eventId: try container.decode(String.self, forKey: .eventId), error: try container.decode(ServerError.self, forKey: .error))
			case "session.created":
				self = .sessionCreated(eventId: try container.decode(String.self, forKey: .eventId), session: try container.decode(RealtimeSession.self, forKey: .session))
			case "session.updated":
				self = .sessionUpdated(eventId: try container.decode(String.self, forKey: .eventId), session: try container.decode(RealtimeSession.self, forKey: .session))
			case "conversation.item.created":
				self = .conversationItemCreated(eventId: try container.decode(String.self, forKey: .eventId), item: try container.decode(Item.self, forKey: .item), previousItemId: try container.decodeIfPresent(String.self, forKey: .previousItemId))
			case "conversation.item.added":
				self = .conversationItemAdded(eventId: try container.decode(String.self, forKey: .eventId), item: try container.decode(Item.self, forKey: .item), previousItemId: try container.decodeIfPresent(String.self, forKey: .previousItemId))
			case "conversation.item.done":
				self = .conversationItemDone(eventId: try container.decode(String.self, forKey: .eventId), item: try container.decode(Item.self, forKey: .item), previousItemId: try container.decodeIfPresent(String.self, forKey: .previousItemId))
			case "conversation.item.retrieved":
				self = .conversationItemRetrieved(eventId: try container.decode(String.self, forKey: .eventId), item: try container.decode(Item.self, forKey: .item))
			case "conversation.item.input_audio_transcription.completed":
				self = .conversationItemInputAudioTranscriptionCompleted(
					eventId: try container.decode(String.self, forKey: .eventId),
					itemId: try container.decode(String.self, forKey: .itemId),
					contentIndex: try container.decode(Int.self, forKey: .contentIndex),
					transcript: try container.decode(String.self, forKey: .transcript),
					logprobs: try container.decodeIfPresent([LogProb].self, forKey: .logprobs),
					usage: try container.decode(Response.Usage.self, forKey: .usage)
				)
			case "conversation.item.input_audio_transcription.delta":
				self = .conversationItemInputAudioTranscriptionDelta(
					eventId: try container.decode(String.self, forKey: .eventId),
					itemId: try container.decode(String.self, forKey: .itemId),
					contentIndex: try container.decode(Int.self, forKey: .contentIndex),
					delta: try container.decode(String.self, forKey: .delta),
					logprobs: try container.decodeIfPresent([LogProb].self, forKey: .logprobs)
				)
			case "conversation.item.input_audio_transcription.segment":
				self = .conversationItemInputAudioTranscriptionSegment(
					eventId: try container.decode(String.self, forKey: .eventId),
					itemId: try container.decode(String.self, forKey: .itemId),
					contentIndex: try container.decode(Int.self, forKey: .contentIndex),
					id: try container.decode(String.self, forKey: .id),
					speaker: try container.decode(String.self, forKey: .speaker),
					text: try container.decode(String.self, forKey: .text),
					start: try container.decode(Double.self, forKey: .start),
					end: try container.decode(Double.self, forKey: .end)
				)
			case "conversation.item.input_audio_transcription.failed":
				self = .conversationItemInputAudioTranscriptionFailed(eventId: try container.decode(String.self, forKey: .eventId), itemId: try container.decode(String.self, forKey: .itemId), contentIndex: try container.decode(Int.self, forKey: .contentIndex), error: try container.decode(ServerError.self, forKey: .error))
			case "conversation.item.truncated":
				self = .conversationItemTruncated(eventId: try container.decode(String.self, forKey: .eventId), itemId: try container.decode(String.self, forKey: .itemId), contentIndex: try container.decode(Int.self, forKey: .contentIndex), audioEndMs: try container.decode(Int.self, forKey: .audioEndMs))
			case "conversation.item.deleted":
				self = .conversationItemDeleted(eventId: try container.decode(String.self, forKey: .eventId), itemId: try container.decode(String.self, forKey: .itemId))
			case "input_audio_buffer.committed":
				self = .inputAudioBufferCommitted(eventId: try container.decode(String.self, forKey: .eventId), itemId: try container.decode(String.self, forKey: .itemId), previousItemId: try container.decodeIfPresent(String.self, forKey: .previousItemId))
			case "input_audio_buffer.cleared":
				self = .inputAudioBufferCleared(eventId: try container.decode(String.self, forKey: .eventId))
			case "input_audio_buffer.speech_started":
				self = .inputAudioBufferSpeechStarted(eventId: try container.decode(String.self, forKey: .eventId), itemId: try container.decode(String.self, forKey: .itemId), audioStartMs: try container.decode(Int.self, forKey: .audioStartMs))
			case "input_audio_buffer.speech_stopped":
				self = .inputAudioBufferSpeechStopped(eventId: try container.decode(String.self, forKey: .eventId), itemId: try container.decode(String.self, forKey: .itemId), audioEndMs: try container.decode(Int.self, forKey: .audioEndMs))
			case "input_audio_buffer.timeout_triggered":
				self = .inputAudioBufferTimeoutTriggered(eventId: try container.decode(String.self, forKey: .eventId), itemId: try container.decode(String.self, forKey: .itemId), audioStartMs: try container.decode(Int.self, forKey: .audioStartMs), audioEndMs: try container.decode(Int.self, forKey: .audioEndMs))
			case "output_audio_buffer.started":
				self = .outputAudioBufferStarted(eventId: try container.decode(String.self, forKey: .eventId), responseId: try container.decode(String.self, forKey: .responseId))
			case "output_audio_buffer.stopped":
				self = .outputAudioBufferStopped(eventId: try container.decode(String.self, forKey: .eventId), responseId: try container.decode(String.self, forKey: .responseId))
			case "response.created":
				self = .responseCreated(eventId: try container.decode(String.self, forKey: .eventId), response: try container.decode(Response.self, forKey: .response))
			case "response.done":
				self = .responseDone(eventId: try container.decode(String.self, forKey: .eventId), response: try container.decode(Response.self, forKey: .response))
			case "response.output_item.added":
				self = .responseOutputItemAdded(eventId: try container.decode(String.self, forKey: .eventId), responseId: try container.decode(String.self, forKey: .responseId), outputIndex: try container.decode(Int.self, forKey: .outputIndex), item: try container.decode(Item.self, forKey: .item))
			case "response.output_item.done":
				self = .responseOutputItemDone(eventId: try container.decode(String.self, forKey: .eventId), responseId: try container.decode(String.self, forKey: .responseId), outputIndex: try container.decode(Int.self, forKey: .outputIndex), item: try container.decode(Item.self, forKey: .item))
			case "response.content_part.added":
				self = .responseContentPartAdded(eventId: try container.decode(String.self, forKey: .eventId), responseId: try container.decode(String.self, forKey: .responseId), itemId: try container.decode(String.self, forKey: .itemId), outputIndex: try container.decode(Int.self, forKey: .outputIndex), contentIndex: try container.decode(Int.self, forKey: .contentIndex), part: try container.decode(Item.ContentPart.self, forKey: .part))
			case "response.content_part.done":
				self = .responseContentPartDone(eventId: try container.decode(String.self, forKey: .eventId), responseId: try container.decode(String.self, forKey: .responseId), itemId: try container.decode(String.self, forKey: .itemId), outputIndex: try container.decode(Int.self, forKey: .outputIndex), contentIndex: try container.decode(Int.self, forKey: .contentIndex), part: try container.decode(Item.ContentPart.self, forKey: .part))
			case "response.text.delta":
				self = .responseTextDelta(eventId: try container.decode(String.self, forKey: .eventId), responseId: try container.decode(String.self, forKey: .responseId), itemId: try container.decode(String.self, forKey: .itemId), outputIndex: try container.decode(Int.self, forKey: .outputIndex), contentIndex: try container.decode(Int.self, forKey: .contentIndex), delta: try container.decode(String.self, forKey: .delta))
			case "response.text.done":
				self = .responseTextDone(eventId: try container.decode(String.self, forKey: .eventId), responseId: try container.decode(String.self, forKey: .responseId), itemId: try container.decode(String.self, forKey: .itemId), outputIndex: try container.decode(Int.self, forKey: .outputIndex), contentIndex: try container.decode(Int.self, forKey: .contentIndex), text: try container.decode(String.self, forKey: .text))
			case "response.output_audio_transcript.delta":
				self = .responseAudioTranscriptDelta(eventId: try container.decode(String.self, forKey: .eventId), responseId: try container.decode(String.self, forKey: .responseId), itemId: try container.decode(String.self, forKey: .itemId), outputIndex: try container.decode(Int.self, forKey: .outputIndex), contentIndex: try container.decode(Int.self, forKey: .contentIndex), delta: try container.decode(String.self, forKey: .delta))
			case "response.output_audio_transcript.done":
				self = .responseAudioTranscriptDone(eventId: try container.decode(String.self, forKey: .eventId), responseId: try container.decode(String.self, forKey: .responseId), itemId: try container.decode(String.self, forKey: .itemId), outputIndex: try container.decode(Int.self, forKey: .outputIndex), contentIndex: try container.decode(Int.self, forKey: .contentIndex), transcript: try container.decode(String.self, forKey: .transcript))
			case "response.output_audio.delta":
				self = .responseOutputAudioDelta(eventId: try container.decode(String.self, forKey: .eventId), responseId: try container.decode(String.self, forKey: .responseId), itemId: try container.decode(String.self, forKey: .itemId), outputIndex: try container.decode(Int.self, forKey: .outputIndex), contentIndex: try container.decode(Int.self, forKey: .contentIndex), delta: try container.decode(AudioData.self, forKey: .delta))
			case "response.output_audio.done":
				self = .responseOutputAudioDone(eventId: try container.decode(String.self, forKey: .eventId), responseId: try container.decode(String.self, forKey: .responseId), itemId: try container.decode(String.self, forKey: .itemId), outputIndex: try container.decode(Int.self, forKey: .outputIndex), contentIndex: try container.decode(Int.self, forKey: .contentIndex))
			case "response.function_call_arguments.delta":
				self = .responseFunctionCallArgumentsDelta(eventId: try container.decode(String.self, forKey: .eventId), responseId: try container.decode(String.self, forKey: .responseId), itemId: try container.decode(String.self, forKey: .itemId), outputIndex: try container.decode(Int.self, forKey: .outputIndex), callId: try container.decode(String.self, forKey: .callId), delta: try container.decode(String.self, forKey: .delta))
			case "response.function_call_arguments.done":
				self = .responseFunctionCallArgumentsDone(eventId: try container.decode(String.self, forKey: .eventId), responseId: try container.decode(String.self, forKey: .responseId), itemId: try container.decode(String.self, forKey: .itemId), outputIndex: try container.decode(Int.self, forKey: .outputIndex), callId: try container.decode(String.self, forKey: .callId), arguments: try container.decode(String.self, forKey: .arguments))
			case "response.mcp_call_arguments.delta":
				self = .responseMCPCallArgumentsDelta(eventId: try container.decode(String.self, forKey: .eventId), responseId: try container.decode(String.self, forKey: .responseId), itemId: try container.decode(String.self, forKey: .itemId), outputIndex: try container.decode(Int.self, forKey: .outputIndex), delta: try container.decode(String.self, forKey: .delta), obfuscation: try container.decodeIfPresent(String.self, forKey: .obfuscation))
			case "response.mcp_call_arguments.done":
				self = .responseMCPCallArgumentsDone(eventId: try container.decode(String.self, forKey: .eventId), responseId: try container.decode(String.self, forKey: .responseId), itemId: try container.decode(String.self, forKey: .itemId), outputIndex: try container.decode(Int.self, forKey: .outputIndex), arguments: try container.decode(String.self, forKey: .arguments))
			case "mcp_list_tools.in_progress":
				self = .mcpListToolsInProgress(eventId: try container.decode(String.self, forKey: .eventId), itemId: try container.decode(String.self, forKey: .itemId))
			case "mcp_list_tools.completed":
				self = .mcpListToolsCompleted(eventId: try container.decode(String.self, forKey: .eventId), itemId: try container.decode(String.self, forKey: .itemId))
			case "mcp_list_tools.failed":
				self = .mcpListToolsFailed(eventId: try container.decode(String.self, forKey: .eventId), itemId: try container.decode(String.self, forKey: .itemId))
			case "response.mcp_call.in_progress":
				self = .responseMCPCallInProgress(eventId: try container.decode(String.self, forKey: .eventId), itemId: try container.decode(String.self, forKey: .itemId), outputIndex: try container.decode(Int.self, forKey: .outputIndex))
			case "response.mcp_call.completed":
				self = .responseMCPCallCompleted(eventId: try container.decode(String.self, forKey: .eventId), itemId: try container.decode(String.self, forKey: .itemId), outputIndex: try container.decode(Int.self, forKey: .outputIndex))
			case "response.mcp_call.failed":
				self = .responseMCPCallFailed(eventId: try container.decode(String.self, forKey: .eventId), itemId: try container.decode(String.self, forKey: .itemId), outputIndex: try container.decode(Int.self, forKey: .outputIndex))
			case "rate_limits.updated":
				self = .rateLimitsUpdated(eventId: try container.decode(String.self, forKey: .eventId), rateLimits: try container.decode([RateLimit].self, forKey: .rateLimits))
			default:
				throw DecodingError.dataCorruptedError(forKey: .type, in: container, debugDescription: "Unknown server event type: \(type)")
		}
	}
}
