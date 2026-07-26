import Foundation

public enum Item: Codable, Identifiable, Equatable, Hashable, Sendable {
	public enum Status: String, Equatable, Hashable, Codable, Sendable {
		case completed, incomplete, inProgress = "in_progress"
	}

	public struct Audio: Equatable, Hashable, Codable, Sendable {
		/// Audio bytes
		public var audio: AudioData?

		/// The transcript of the audio
		public var transcript: String?

		public init(audio: AudioData? = nil, transcript: String? = nil) {
			self.audio = audio
			self.transcript = transcript
		}

		public init(audio: Data? = nil, transcript: String? = nil) {
			self.init(audio: audio.map { AudioData(data: $0) }, transcript: transcript)
		}
	}

	public enum ContentPart: Equatable, Hashable, Sendable {
		case text(String)
		case audio(Audio)
	}

	public struct Message: Identifiable, Equatable, Hashable, Codable, Sendable {
		public enum Role: String, Equatable, Hashable, Codable, Sendable {
			case system, assistant, user
		}

		public enum Content: Equatable, Hashable, Sendable {
			case text(String)
			case audio(Audio)
			case inputText(String)
			case inputAudio(Audio)

			public var text: String? {
				switch self {
					case let .text(text): text
					case let .inputText(text): text
					case let .audio(audio): audio.transcript
					case let .inputAudio(audio): audio.transcript
				}
			}
		}

		/// The unique ID of the item.
		public var id: String

		/// The status of the item. Has no effect on the conversation.
		public var status: Status

		/// The role of the message sender.
		public var role: Role

		/// The content of the message.
		public var content: [Content]

		public init(id: String, status: Status = .completed, role: Role, content: [Content]) {
			self.id = id
			self.role = role
			self.status = status
			self.content = content
		}
	}

	/// A function call item in a Realtime conversation.
	public struct FunctionCall: Identifiable, Equatable, Hashable, Codable, Sendable {
		/// The unique ID of the item.
		public var id: String

		/// The status of the item. Has no effect on the conversation.
		public var status: Status

		/// The ID of the function call
		public var callId: String

		/// The name of the function being called
		public var name: String

		/// The arguments of the function call
		public var arguments: String

		/// Creates a new `FunctionCall` instance.
		///
		/// - Parameter id: The unique ID of the item.
		/// - Parameter status: The status of the item. Has no effect on the conversation
		/// - Parameter callId: The ID of the function call.
		/// - Parameter name: The name of the function being called.
		public init(id: String, status: Status, callId: String, name: String, arguments: String) {
			self.id = id
			self.name = name
			self.status = status
			self.callId = callId
			self.arguments = arguments
		}
	}

	/// A function call output item in a Realtime conversation.
	public struct FunctionCallOutput: Identifiable, Equatable, Hashable, Codable, Sendable {
		/// The unique ID of the item.
		public var id: String

		/// The ID of the function call
		public var callId: String

		/// The output of the function call
		public var output: String

		/// Creates a new `FunctionCallOutput` instance.
		///
		/// - Parameter id: The unique ID of the item.
		/// - Parameter callId: The ID of the function call.
		/// - Parameter output: The output of the function call.
		public init(id: String, callId: String, output: String) {
			self.id = id
			self.callId = callId
			self.output = output
		}
	}

	/// A Realtime item representing an invocation of a tool on an MCP server.
	public struct MCPToolCall: Codable, Identifiable, Equatable, Hashable, Sendable {
		/// An error that occurred during the MCP call.
		public struct Error: Equatable, Hashable, Codable, Sendable {
			public var code: Int?
			public var type: String
			public var message: String

			/// Creates a new `Error` instance.
			public init(code: Int? = nil, type: String, message: String) {
				self.code = code
				self.type = type
				self.message = message
			}
		}

		/// The unique ID of the tool call.
		public var id: String

		/// The label of the MCP server running the tool.
		public var server: String

		/// The name of the tool that was run.
		public var tool: String

		/// A JSON string of the arguments passed to the tool.
		public var arguments: String

		/// The output from the tool call.
		public var output: String?

		/// The error from the tool call, if any.
		public var error: Error?

		/// The ID of an associated approval request, if any.
		public var approvalRequestId: String?

		/// Creates a new `MCPToolCall` instance.
		///
		/// - Parameter id: The unique ID of the tool call.
		/// - Parameter server: The label of the MCP server running the tool.
		/// - Parameter tool: The name of the tool that was run.
		/// - Parameter arguments: A JSON string of the arguments passed to the tool.
		/// - Parameter output: The output from the tool call.
		/// - Parameter error: The error from the tool call, if any.
		/// - Parameter approvalRequestId: The ID of an associated approval request, if any.
		public init(id: String, server: String, tool: String, arguments: String, output: String? = nil, error: Error? = nil, approvalRequestId: String? = nil) {
			self.id = id
			self.tool = tool
			self.error = error
			self.server = server
			self.output = output
			self.arguments = arguments
			self.approvalRequestId = approvalRequestId
		}
	}

	/// A Realtime item requesting human approval of a tool invocation.
	public struct MCPApprovalRequest: Codable, Identifiable, Equatable, Hashable, Sendable {
		/// The unique ID of the approval request.
		public var id: String

		/// The label of the MCP server making the request.
		public var server: String

		/// The name of the tool to run.
		public var tool: String

		/// A JSON string of arguments for the tool.
		public var arguments: String

		/// Creates a new `MCPApprovalRequest` instance.
		///
		/// - Parameter id: The unique ID of the approval request.
		/// - Parameter server: The label of the MCP server making the request.
		/// - Parameter tool: The name of the tool to run.
		/// - Parameter arguments: A JSON string of arguments for the tool.
		public init(id: String, server: String, tool: String, arguments: String) {
			self.id = id
			self.tool = tool
			self.server = server
			self.arguments = arguments
		}
	}

	/// A Realtime item responding to an MCP approval request.
	public struct MCPApprovalResponse: Codable, Identifiable, Equatable, Hashable, Sendable {
		/// The unique ID of the approval response.
		public var id: String

		/// The ID of the approval request being answered.
		public var approvalRequestId: String

		/// Whether the request was approved.
		public var approve: Bool

		/// Optional reason for the decision.
		public var reason: String?

		/// Creates a new `MCPApprovalResponse` instance.
		///
		/// - Parameter id: The unique ID of the approval response.
		/// - Parameter approvalRequestId: The ID of the approval request being answered.
		/// - Parameter approve: Whether the request was approved.
		/// - Parameter reason: Optional reason for the decision.
		public init(id: String, approvalRequestId: String, approve: Bool, reason: String? = nil) {
			self.id = id
			self.approvalRequestId = approvalRequestId
			self.approve = approve
			self.reason = reason
		}
	}

	public struct MCPListTools: Codable, Identifiable, Equatable, Hashable, Sendable {
		public struct Tool: Equatable, Hashable, Codable, Sendable {
			/// Additional annotations about the tool.
			public struct Annotations: Equatable, Hashable, Codable, Sendable {
				/// A human-readable title for the tool
				public var title: String?

				/// If true, the tool may perform destructive updates to its environment.
				/// If false, the tool performs only additive updates.
				public var destructiveHint: Bool?

				/// If true, calling the tool repeatedly with the same arguments will have no additional effect on its environment.
				public var idempotentHint: Bool?

				/// If true, this tool may interact with an "open world" of external
				/// entities. If false, the tool's domain of interaction is closed.
				/// For example, the world of a web search tool is open, whereas that
				/// of a memory tool is not.
				public var openWorldHint: Bool?

				/// If true, the tool does not modify its environment.
				public var readOnlyHint: Bool?

				/// Creates a new set of annotations for a tool.
				///
				/// - Parameter title: A human-readable title for the tool.
				/// - Parameter destructiveHint: If true, the tool may perform destructive updates to its environment.
				/// - Parameter idempotentHint: If true, calling the tool repeatedly with the same arguments will have no additional effect on its environment.
				/// - Parameter openWorldHint: If true, this tool may interact with an "open world" of external entities.
				/// - Parameter readOnlyHint: If true, the tool does not modify its environment.
				public init(title: String? = nil, destructiveHint: Bool? = nil, idempotentHint: Bool? = nil, openWorldHint: Bool? = nil, readOnlyHint: Bool? = nil) {
					self.title = title
					self.readOnlyHint = readOnlyHint
					self.openWorldHint = openWorldHint
					self.idempotentHint = idempotentHint
					self.destructiveHint = destructiveHint
				}
			}

			/// The name of the tool.
			public var name: String

			/// The description of the tool.
			public var description: String?

			/// The JSON schema describing the tool's input.
			public var inputSchema: JSONSchema

			/// Additional annotations about the tool.
			public var annotations: Annotations?

			/// Creates a new tool description.
			///
			/// - Parameter name: The name of the tool.
			/// - Parameter description: The description of the tool.
			/// - Parameter inputSchema: The JSON schema describing the tool's input.
			/// - Parameter annotations: Additional annotations about the tool.
			public init(name: String, description: String? = nil, inputSchema: JSONSchema, annotations: Annotations? = nil) {
				self.name = name
				self.description = description
				self.inputSchema = inputSchema
				self.annotations = annotations
			}
		}

		/// The unique ID of the list.
		public var id: String

		/// The label of the MCP server.
		public var server: String

		/// The tools available on the server.
		public var tools: [Tool]
	}

	/// A message item in a Realtime conversation.
	case message(Message)

	/// A function call item in a Realtime conversation.
	case functionCall(FunctionCall)

	/// A function call output item in a Realtime conversation.
	case functionCallOutput(FunctionCallOutput)

	/// A Realtime item representing an invocation of a tool on an MCP server.
	case mcpToolCall(MCPToolCall)

	/// A Realtime item requesting human approval of a tool invocation.
	case mcpApprovalRequest(MCPApprovalRequest)

	/// A Realtime item responding to an MCP approval request.
	case mcpApprovalResponse(MCPApprovalResponse)

	/// A Realtime item listing tools available on an MCP server.
	case mcpListTools(MCPListTools)

	public var id: String {
		switch self {
			case let .message(message): message.id
			case let .mcpToolCall(mcpToolCall): mcpToolCall.id
			case let .mcpListTools(mcpListTools): mcpListTools.id
			case let .functionCall(functionCall): functionCall.id
			case let .functionCallOutput(functionCallOutput): functionCallOutput.id
			case let .mcpApprovalRequest(mcpApprovalRequest): mcpApprovalRequest.id
			case let .mcpApprovalResponse(mcpApprovalResponse): mcpApprovalResponse.id
		}
	}
}

extension Item.MCPToolCall {
	private enum CodingKeys: String, CodingKey {
		case id
		case server = "server_label"
		case tool = "name"
		case arguments
		case output
		case error
		case approvalRequestId
	}

	public func encode(to encoder: any Encoder) throws {
		var container = encoder.container(keyedBy: CodingKeys.self)
		try container.encode(id, forKey: .id)
		try container.encode(server, forKey: .server)
		try container.encode(tool, forKey: .tool)
		try container.encode(arguments, forKey: .arguments)
		try container.encodeIfPresent(output, forKey: .output)
		try container.encodeIfPresent(error, forKey: .error)
		try container.encodeIfPresent(approvalRequestId, forKey: .approvalRequestId)
	}

	public init(from decoder: any Decoder) throws {
		let container = try decoder.container(keyedBy: CodingKeys.self)
		self.id = try container.decode(String.self, forKey: .id)
		self.server = try container.decode(String.self, forKey: .server)
		self.tool = try container.decode(String.self, forKey: .tool)
		self.arguments = try container.decode(String.self, forKey: .arguments)
		self.output = try container.decodeIfPresent(String.self, forKey: .output)
		self.error = try container.decodeIfPresent(Error.self, forKey: .error)
		self.approvalRequestId = try container.decodeIfPresent(String.self, forKey: .approvalRequestId)
	}
}

extension Item.MCPApprovalRequest {
	private enum CodingKeys: String, CodingKey {
		case id
		case server = "server_label"
		case tool = "name"
		case arguments
	}

	public func encode(to encoder: any Encoder) throws {
		var container = encoder.container(keyedBy: CodingKeys.self)
		try container.encode(id, forKey: .id)
		try container.encode(server, forKey: .server)
		try container.encode(tool, forKey: .tool)
		try container.encode(arguments, forKey: .arguments)
	}

	public init(from decoder: any Decoder) throws {
		let container = try decoder.container(keyedBy: CodingKeys.self)
		self.id = try container.decode(String.self, forKey: .id)
		self.server = try container.decode(String.self, forKey: .server)
		self.tool = try container.decode(String.self, forKey: .tool)
		self.arguments = try container.decode(String.self, forKey: .arguments)
	}
}

extension Item.MCPApprovalResponse {
	private enum CodingKeys: String, CodingKey {
		case id
		case approvalRequestId
		case approve
		case reason
	}

	public func encode(to encoder: any Encoder) throws {
		var container = encoder.container(keyedBy: CodingKeys.self)
		try container.encode(id, forKey: .id)
		try container.encode(approvalRequestId, forKey: .approvalRequestId)
		try container.encode(approve, forKey: .approve)
		try container.encodeIfPresent(reason, forKey: .reason)
	}

	public init(from decoder: any Decoder) throws {
		let container = try decoder.container(keyedBy: CodingKeys.self)
		self.id = try container.decode(String.self, forKey: .id)
		self.approvalRequestId = try container.decode(String.self, forKey: .approvalRequestId)
		self.approve = try container.decode(Bool.self, forKey: .approve)
		self.reason = try container.decodeIfPresent(String.self, forKey: .reason)
	}
}

extension Item.MCPListTools {
	private enum CodingKeys: String, CodingKey {
		case id
		case server = "server_label"
		case tools
	}

	public func encode(to encoder: any Encoder) throws {
		var container = encoder.container(keyedBy: CodingKeys.self)
		try container.encode(id, forKey: .id)
		try container.encode(server, forKey: .server)
		try container.encode(tools, forKey: .tools)
	}

	public init(from decoder: any Decoder) throws {
		let container = try decoder.container(keyedBy: CodingKeys.self)
		self.id = try container.decode(String.self, forKey: .id)
		self.server = try container.decode(String.self, forKey: .server)
		self.tools = try container.decode([Tool].self, forKey: .tools)
	}
}

extension Item {
	private enum CodingKeys: String, CodingKey {
		case type
		case id
		case status
		case role
		case content
		case callId
		case name
		case arguments
		case server = "server_label"
		case tool
		case output
		case error
		case approvalRequestId
		case previousItemId
		case approve
		case reason
		case tools
	}

	public func encode(to encoder: any Encoder) throws {
		var container = encoder.container(keyedBy: CodingKeys.self)

		switch self {
			case let .message(message):
				try container.encode("message", forKey: .type)
				try container.encode(message.id, forKey: .id)
				try container.encode(message.status, forKey: .status)
				try container.encode(message.role, forKey: .role)
				try container.encode(message.content, forKey: .content)
			case let .functionCall(functionCall):
				try container.encode("function_call", forKey: .type)
				try container.encode(functionCall.id, forKey: .id)
				try container.encode(functionCall.status, forKey: .status)
				try container.encode(functionCall.callId, forKey: .callId)
				try container.encode(functionCall.name, forKey: .name)
				try container.encode(functionCall.arguments, forKey: .arguments)
			case let .functionCallOutput(functionCallOutput):
				try container.encode("function_call_output", forKey: .type)
				try container.encode(functionCallOutput.id, forKey: .id)
				try container.encode(functionCallOutput.callId, forKey: .callId)
				try container.encode(functionCallOutput.output, forKey: .output)
			case let .mcpToolCall(mcpToolCall):
				try container.encode("mcp_tool_call", forKey: .type)
				try container.encode(mcpToolCall.id, forKey: .id)
				try container.encode(mcpToolCall.server, forKey: .server)
				try container.encode(mcpToolCall.tool, forKey: .tool)
				try container.encode(mcpToolCall.arguments, forKey: .arguments)
				try container.encodeIfPresent(mcpToolCall.output, forKey: .output)
				try container.encodeIfPresent(mcpToolCall.error, forKey: .error)
				try container.encodeIfPresent(mcpToolCall.approvalRequestId, forKey: .approvalRequestId)
			case let .mcpApprovalRequest(mcpApprovalRequest):
				try container.encode("mcp_approval_request", forKey: .type)
				try container.encode(mcpApprovalRequest.id, forKey: .id)
				try container.encode(mcpApprovalRequest.server, forKey: .server)
				try container.encode(mcpApprovalRequest.tool, forKey: .tool)
				try container.encode(mcpApprovalRequest.arguments, forKey: .arguments)
			case let .mcpApprovalResponse(mcpApprovalResponse):
				try container.encode("mcp_approval_response", forKey: .type)
				try container.encode(mcpApprovalResponse.id, forKey: .id)
				try container.encode(mcpApprovalResponse.approvalRequestId, forKey: .approvalRequestId)
				try container.encode(mcpApprovalResponse.approve, forKey: .approve)
				try container.encodeIfPresent(mcpApprovalResponse.reason, forKey: .reason)
			case let .mcpListTools(mcpListTools):
				try container.encode("mcp_list_tools", forKey: .type)
				try container.encode(mcpListTools.id, forKey: .id)
				try container.encode(mcpListTools.server, forKey: .server)
				try container.encode(mcpListTools.tools, forKey: .tools)
		}
	}

	public init(from decoder: any Decoder) throws {
		let container = try decoder.container(keyedBy: CodingKeys.self)
		let type = try container.decode(String.self, forKey: .type)

		switch type {
			case "message":
				self = .message(try Message(from: decoder))
			case "function_call":
				self = .functionCall(try FunctionCall(from: decoder))
			case "function_call_output":
				self = .functionCallOutput(try FunctionCallOutput(from: decoder))
			case "mcp_tool_call":
				self = .mcpToolCall(try MCPToolCall(from: decoder))
			case "mcp_approval_request":
				self = .mcpApprovalRequest(try MCPApprovalRequest(from: decoder))
			case "mcp_approval_response":
				self = .mcpApprovalResponse(try MCPApprovalResponse(from: decoder))
			case "mcp_list_tools":
				self = .mcpListTools(try MCPListTools(from: decoder))
			default:
				throw DecodingError.dataCorruptedError(forKey: .type, in: container, debugDescription: "Unknown item type: \(type)")
		}
	}

}

// MARK: Helpers

public extension Item.Message.Content {
	init(from part: Item.ContentPart) {
		switch part {
			case let .text(text): self = .text(text)
			case let .audio(audio): self = .audio(audio)
		}
	}
}

// MARK: Codable implementations

extension Item.ContentPart: Codable {
	private enum CodingKeys: String, CodingKey {
		case type, text, audio, transcript
	}

	private struct Text: Codable {
		let text: String

		enum CodingKeys: CodingKey {
			case text
		}
	}

	public init(from decoder: any Decoder) throws {
		let container = try decoder.container(keyedBy: CodingKeys.self)
		let type = try container.decode(String.self, forKey: .type)

		switch type {
			case "text":
				let container = try decoder.container(keyedBy: Text.CodingKeys.self)
				self = try .text(container.decode(String.self, forKey: .text))
			case "audio":
				self = try .audio(Item.Audio(from: decoder))
			default:
				throw DecodingError.dataCorruptedError(forKey: .type, in: container, debugDescription: "Unknown content type: \(type)")
		}
	}

	public func encode(to encoder: Encoder) throws {
		var container = encoder.container(keyedBy: CodingKeys.self)

		switch self {
			case let .text(text):
				try container.encode(text, forKey: .text)
				try container.encode("text", forKey: .type)
			case let .audio(audio):
				try container.encode("audio", forKey: .type)
				try container.encodeIfPresent(audio.transcript, forKey: .transcript)
				try container.encodeIfPresent(audio.audio, forKey: .audio)
		}
	}
}

extension Item.Message.Content: Codable {
	private enum CodingKeys: String, CodingKey {
		case type
		case text
		case audio
		case transcript
	}

	private struct Text: Codable {
		let text: String

		enum CodingKeys: CodingKey {
			case text
		}
	}

	public init(from decoder: any Decoder) throws {
		let container = try decoder.container(keyedBy: CodingKeys.self)
		let type = try container.decode(String.self, forKey: .type)

		switch type {
			case "text":
				let container = try decoder.container(keyedBy: Text.CodingKeys.self)
				self = try .text(container.decode(String.self, forKey: .text))
			case "input_text":
				let container = try decoder.container(keyedBy: Text.CodingKeys.self)
				self = try .inputText(container.decode(String.self, forKey: .text))
			case "output_audio":
				self = try .audio(Item.Audio(from: decoder))
			case "input_audio":
				self = try .inputAudio(Item.Audio(from: decoder))
			default:
				throw DecodingError.dataCorruptedError(forKey: .type, in: container, debugDescription: "Unknown content type: \(type)")
		}
	}

	public func encode(to encoder: Encoder) throws {
		var container = encoder.container(keyedBy: CodingKeys.self)

		switch self {
			case let .text(text):
				try container.encode(text, forKey: .text)
				try container.encode("text", forKey: .type)
			case let .inputText(text):
				try container.encode(text, forKey: .text)
				try container.encode("input_text", forKey: .type)
			case let .audio(audio):
				try container.encode("output_audio", forKey: .type)
				try container.encodeIfPresent(audio.audio, forKey: .audio)
				try container.encodeIfPresent(audio.transcript, forKey: .transcript)
			case let .inputAudio(audio):
				try container.encode("input_audio", forKey: .type)
				try container.encodeIfPresent(audio.audio, forKey: .audio)
				try container.encodeIfPresent(audio.transcript, forKey: .transcript)
		}
	}
}
