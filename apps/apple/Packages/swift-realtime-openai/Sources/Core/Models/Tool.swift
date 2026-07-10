import Foundation

public enum Tool: Codable, Equatable, Hashable, Sendable {
	public enum Choice: Equatable, Hashable, Sendable {
		/// The model will not call any tool and instead generates a message.
		case none

		/// The model can pick between generating a message or calling one or more tools.
		case auto

		/// The model must call one or more tools.
		case required

		/// Force the model to call a specific function.
		///
		/// - Parameter name: The name of the function to call.
		case function(name: String)

		/// Force the model to call a specific tool on a remote MCP server.
		///
		/// - Parameter server: The label of the MCP server to use.
		/// - Parameter tool: The name of the tool to call on the server.
		case mcp(server: String, tool: String?)
	}

	public struct Function: Equatable, Hashable, Codable, Sendable {
		/// The name of the function.
		public var name: String

		/// The description of the function, including guidance on when and how to call it, and guidance about what to tell the user when calling it (if anything).
		public var description: String?

		/// A JSON schema object describing the parameters of the function.
		public var parameters: JSONSchema

		public init(name: String, description: String? = nil, parameters: JSONSchema) {
			self.name = name
			self.parameters = parameters
			self.description = description
		}
	}

	public struct MCP: Codable, Equatable, Hashable, Sendable {
		public enum Connector: String, Equatable, Hashable, Codable, Sendable {
			case gmail = "connector_gmail"
			case dropbox = "connector_dropbox"
			case sharepoint = "connector_sharepoint"
			case googleDrive = "connector_googledrive"
			case outlookEmail = "connector_outlookemail"
			case googleCalendar = "connector_googlecalendar"
			case microsoftTeams = "connector_microsoftteams"
			case outlookCalendar = "connector_outlookcalendar"
		}

		public enum RequireApproval: Equatable, Hashable, Sendable {
			/// Approval policies for MCP tools.
			public enum Approval: String, CaseIterable, Equatable, Hashable, Codable, Sendable {
				case always
				case never
			}

			/// Specify a single approval policy for all tools
			case all(Approval)

			/// Set approval requirements for specific tools on this MCP server.
			///
			/// - Parameter always: Tools that always require approval.
			/// - Parameter never: Tools that never require approval.
			case granular(always: [String]? = nil, never: [String]? = nil)
		}

		/// A label for this MCP server, used to identify it in tool calls.
		public var label: String

		/// The URL for the MCP server.
		public var url: URL?

		/// Identifier for service connectors, like those available in ChatGPT.
		///
		/// Learn more about service connectors [here](https://platform.openai.com/docs/guides/tools-remote-mcp#connectors).
		public var connector: Connector?

		/// An OAuth access token that can be used with a remote MCP server, either with a custom MCP server URL or a service connector.
		///
		/// Your application must handle the OAuth authorization flow and provide the token here.
		public var authorization: String?

		/// List of allowed tool names.
		public var allowedTools: [String]?

		/// Optional HTTP headers to send to the MCP server.
		///
		/// Use for authentication or other purposes.
		public var headers: [String: String]?

		/// Specify which of the MCP server's tools require approval.
		public var requireApproval: RequireApproval?

		/// Optional description of the MCP server, used to provide more context.
		public var description: String?

		/// Create a new `MCP` instance for a remote MCP server.
		///
		/// - Parameter label: A label for this MCP server, used to identify it in tool calls.
		/// - Parameter url: The URL for the MCP server.
		/// - Parameter authorization: An OAuth access token that can be used with a remote MCP server.
		/// - Parameter allowedTools: List of allowed tool names.
		/// - Parameter headers: Optional HTTP headers to send to the MCP server.
		/// - Parameter requireApproval: Specify which of the MCP server's tools require approval.
		/// - Parameter description: Optional description of the MCP server, used to provide more context.
		public init(label: String, url: URL, authorization: String? = nil, allowedTools: [String]? = nil, headers: [String: String]? = nil, requireApproval: RequireApproval? = nil, description: String? = nil) {
			self.url = url
			self.label = label
			self.headers = headers
			self.description = description
			self.allowedTools = allowedTools
			self.authorization = authorization
			self.requireApproval = requireApproval
		}

		/// Create a new `MCP` instance for a service connector.
		///
		/// - Parameter label: A label for this MCP server, used to identify it in tool calls.
		/// - Parameter connector: Identifier for service connectors, like those available in ChatGPT.
		/// - Parameter authorization: An OAuth access token that can be used with the connector.
		/// - Parameter allowedTools: List of allowed tool names.
		/// - Parameter headers: Optional HTTP headers to send to the MCP server.
		/// - Parameter requireApproval: Specify which of the MCP server's tools require approval.
		/// - Parameter description: Optional description of the MCP server, used to provide more context.
		public init(label: String, connector: Connector, authorization: String, allowedTools: [String]? = nil, headers: [String: String]? = nil, requireApproval: RequireApproval? = nil, description: String? = nil) {
			self.label = label
			self.headers = headers
			self.connector = connector
			self.description = description
			self.allowedTools = allowedTools
			self.authorization = authorization
			self.requireApproval = requireApproval
		}
	}

	case mcp(MCP)
	case function(Function)
}

extension Tool {
	private enum CodingKeys: String, CodingKey {
		case type
		case label = "server_label"
		case url = "server_url"
		case connector = "connector_id"
		case authorization
		case allowedTools
		case headers
		case requireApproval
		case description = "server_description"
		case name
		case parameters
	}

	public func encode(to encoder: any Encoder) throws {
		var container = encoder.container(keyedBy: CodingKeys.self)

		switch self {
			case let .mcp(mcp):
				try container.encode("mcp", forKey: .type)
				try container.encode(mcp.label, forKey: .label)
				try container.encodeIfPresent(mcp.url, forKey: .url)
				try container.encodeIfPresent(mcp.connector, forKey: .connector)
				try container.encodeIfPresent(mcp.authorization, forKey: .authorization)
				try container.encodeIfPresent(mcp.allowedTools, forKey: .allowedTools)
				try container.encodeIfPresent(mcp.headers, forKey: .headers)
				try container.encodeIfPresent(mcp.requireApproval, forKey: .requireApproval)
				try container.encodeIfPresent(mcp.description, forKey: .description)
			case let .function(function):
				try container.encode("function", forKey: .type)
				try container.encode(function.name, forKey: .name)
				try container.encodeIfPresent(function.description, forKey: .description)
				try container.encode(function.parameters, forKey: .parameters)
		}
	}

	public init(from decoder: any Decoder) throws {
		let container = try decoder.container(keyedBy: CodingKeys.self)
		let type = try container.decode(String.self, forKey: .type)

		switch type {
			case "mcp":
				self = .mcp(try MCP(from: decoder))
			case "function":
				self = .function(try Function(from: decoder))
			default:
				throw DecodingError.dataCorruptedError(forKey: .type, in: container, debugDescription: "Invalid tool type: \(type)")
		}
	}
}

extension Tool.MCP {
	private enum CodingKeys: String, CodingKey {
		case label = "server_label"
		case url = "server_url"
		case connector = "connector_id"
		case authorization
		case allowedTools
		case headers
		case requireApproval
		case description = "server_description"
	}

	public func encode(to encoder: any Encoder) throws {
		var container = encoder.container(keyedBy: CodingKeys.self)
		try container.encode(label, forKey: .label)
		try container.encodeIfPresent(url, forKey: .url)
		try container.encodeIfPresent(connector, forKey: .connector)
		try container.encodeIfPresent(authorization, forKey: .authorization)
		try container.encodeIfPresent(allowedTools, forKey: .allowedTools)
		try container.encodeIfPresent(headers, forKey: .headers)
		try container.encodeIfPresent(requireApproval, forKey: .requireApproval)
		try container.encodeIfPresent(description, forKey: .description)
	}

	public init(from decoder: any Decoder) throws {
		let container = try decoder.container(keyedBy: CodingKeys.self)
		self.label = try container.decode(String.self, forKey: .label)
		self.url = try container.decodeIfPresent(URL.self, forKey: .url)
		self.connector = try container.decodeIfPresent(Connector.self, forKey: .connector)
		self.authorization = try container.decodeIfPresent(String.self, forKey: .authorization)
		self.allowedTools = try container.decodeIfPresent([String].self, forKey: .allowedTools)
		self.headers = try container.decodeIfPresent([String: String].self, forKey: .headers)
		self.requireApproval = try container.decodeIfPresent(RequireApproval.self, forKey: .requireApproval)
		self.description = try container.decodeIfPresent(String.self, forKey: .description)
	}
}

extension Tool.Choice: Codable {
	enum CodingKeys: String, CodingKey {
		case type
		case name
		case mode
		case tools
		case serverLabel = "server_label"
	}

	public func encode(to encoder: any Encoder) throws {
		switch self {
			case .none: try "none".encode(to: encoder)
			case .auto: try "auto".encode(to: encoder)
			case .required: try "required".encode(to: encoder)
			case let .function(name):
				var container = encoder.container(keyedBy: CodingKeys.self)
				try container.encode("function", forKey: .type)
				try container.encode(name, forKey: .name)
			case let .mcp(server, name):
				var container = encoder.container(keyedBy: CodingKeys.self)
				try container.encode("mcp", forKey: .type)
				try container.encode(server, forKey: .serverLabel)
				if let name { try container.encode(name, forKey: .name) }
		}
	}

	public init(from decoder: any Decoder) throws {
		if let string = try? String(from: decoder) {
			switch string {
				case "none": self = .none
				case "auto": self = .auto
				case "required": self = .required
				default: throw DecodingError.dataCorrupted(DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "Invalid tool choice: \(string)"))
			}
			return
		}

		let container = try decoder.container(keyedBy: CodingKeys.self)
		let type = try container.decode(String.self, forKey: .type)

		switch type {
			case "function":
				let name = try container.decode(String.self, forKey: .name)
				self = .function(name: name)
			case "mcp":
				let server = try container.decode(String.self, forKey: .serverLabel)
				let tool = try container.decodeIfPresent(String.self, forKey: .name)
				self = .mcp(server: server, tool: tool)
			default:
				throw DecodingError.dataCorruptedError(forKey: .type, in: container, debugDescription: "Invalid tool choice: \(type)")
		}
	}
}

extension Tool.MCP.RequireApproval: Codable {
	static let never = Self.all(.never)
	static let always = Self.all(.always)

	private enum CodingKeys: String, CodingKey {
		case always, never
	}

	private struct ToolList: Codable {
		var toolNames: [String]

		private enum CodingKeys: String, CodingKey {
			case toolNames = "tool_names"
		}
	}

	public func encode(to encoder: any Encoder) throws {
		switch self {
			case let .all(approval):
				var container = encoder.singleValueContainer()
				try container.encode(approval.rawValue)
			case let .granular(always, never):
				var container = encoder.container(keyedBy: CodingKeys.self)
				if let always {
					try container.encode(ToolList(toolNames: always), forKey: .always)
				}
				if let never {
					try container.encode(ToolList(toolNames: never), forKey: .never)
				}
		}
	}

	public init(from decoder: any Decoder) throws {
		if let approval = try? Approval(from: decoder) {
			self = .all(approval)
			return
		}

		let container = try decoder.container(keyedBy: CodingKeys.self)
		self = try .granular(
			always: container.decode(ToolList?.self, forKey: .always)?.toolNames,
			never: container.decode(ToolList?.self, forKey: .never)?.toolNames
		)
	}
}
