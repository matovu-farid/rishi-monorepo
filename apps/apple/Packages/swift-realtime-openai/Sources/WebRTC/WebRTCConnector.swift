import Core
import AVFAudio
import Foundation
@preconcurrency import LiveKitWebRTC
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

@Observable public final class WebRTCConnector: NSObject, Connector, Sendable {
	public enum WebRTCError: Error {
		case invalidEphemeralKey
		case missingAudioPermission
		case failedToCreateDataChannel
		case failedToCreatePeerConnection
		case badServerResponse(URLResponse)
		case failedToCreateSDPOffer(Swift.Error)
		case failedToSetLocalDescription(Swift.Error)
		case failedToSetRemoteDescription(Swift.Error)
	}

	public let events: AsyncThrowingStream<ServerEvent, Error>
	public let statusUpdates: AsyncStream<RealtimeAPI.Status>
	@MainActor public private(set) var status = RealtimeAPI.Status.disconnected

	public var isMuted: Bool {
		!audioTrack.isEnabled
	}

	package let audioTrack: LKRTCAudioTrack
	private let dataChannel: LKRTCDataChannel
	private let connection: LKRTCPeerConnection

	private let stream: AsyncThrowingStream<ServerEvent, Error>.Continuation
	private let statusStream: AsyncStream<RealtimeAPI.Status>.Continuation

	private static let factory: LKRTCPeerConnectionFactory = {
		LKRTCInitializeSSL()

		return LKRTCPeerConnectionFactory()
	}()

	private let encoder: JSONEncoder = {
		let encoder = JSONEncoder()
		encoder.keyEncodingStrategy = .convertToSnakeCase
		return encoder
	}()

	private let decoder: JSONDecoder = {
		let decoder = JSONDecoder()
		decoder.keyDecodingStrategy = .convertFromSnakeCase
		return decoder
	}()

	private init(connection: LKRTCPeerConnection, audioTrack: LKRTCAudioTrack, dataChannel: LKRTCDataChannel) {
		self.connection = connection
		self.audioTrack = audioTrack
		self.dataChannel = dataChannel
		(events, stream) = AsyncThrowingStream.makeStream(of: ServerEvent.self)
		(statusUpdates, statusStream) = AsyncStream.makeStream(of: RealtimeAPI.Status.self)

		super.init()

		connection.delegate = self
		dataChannel.delegate = self
	}

	deinit {
		disconnect()
	}

	/// Connects the WebRTC peer and returns the OpenAI-assigned Realtime call
	/// ID captured from the `Location` header (`nil` if the header was
	/// missing/malformed on an otherwise-successful handshake, or if this call
	/// was a no-op because the peer was already connected/connecting).
	@discardableResult
	package func connect(using request: URLRequest) async throws -> String? {
		guard connection.connectionState == .new else { return nil }

		guard AVAudioApplication.shared.recordPermission == .granted else {
			throw WebRTCError.missingAudioPermission
		}

		let providerCallId = try await performHandshake(using: request)
		Self.configureAudioSession()
		return providerCallId
	}

	public func send(event: ClientEvent) throws {
		try dataChannel.sendData(LKRTCDataBuffer(data: encoder.encode(event), isBinary: false))
	}

	public func disconnect() {
		connection.close()
		stream.finish()
		statusStream.finish()
	}

	public func toggleMute() {
		audioTrack.isEnabled.toggle()
	}
}

extension WebRTCConnector {
	public static func create(connectingTo request: URLRequest) async throws -> WebRTCConnector {
		let connector = try create()
		_ = try await connector.connect(using: request)
		return connector
	}

	package static func create() throws -> WebRTCConnector {
		guard let connection = factory.peerConnection(
			with: LKRTCConfiguration(),
			constraints: LKRTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil),
			delegate: nil
		) else { throw WebRTCError.failedToCreatePeerConnection }

		let audioTrack = Self.setupLocalAudio(for: connection)

		guard let dataChannel = connection.dataChannel(forLabel: "oai-events", configuration: LKRTCDataChannelConfiguration()) else {
			throw WebRTCError.failedToCreateDataChannel
		}

		return self.init(connection: connection, audioTrack: audioTrack, dataChannel: dataChannel)
	}
}

private extension WebRTCConnector {
	static func setupLocalAudio(for connection: LKRTCPeerConnection) -> LKRTCAudioTrack {
		let audioSource = factory.audioSource(with: LKRTCMediaConstraints(
			mandatoryConstraints: [
				"googNoiseSuppression": "true", "googHighpassFilter": "true",
				"googEchoCancellation": "true", "googAutoGainControl": "true",
			],
			optionalConstraints: nil
		))

		return tap(factory.audioTrack(with: audioSource, trackId: "local_audio")) { audioTrack in
			connection.add(audioTrack, streamIds: ["local_stream"])
		}
	}

	static func configureAudioSession() {
		#if !os(macOS)
		do {
			let audioSession = AVAudioSession.sharedInstance()
			// Rishi's AudioSessionCoordinator already configures voice chat
			// before WebRTC connects. Re-applying category/mode mid-activation
			// (while AVAudioEngine may still be recording) destabilizes ICE.
			if audioSession.category == .playAndRecord, audioSession.mode == .videoChat {
				return
			}
			#if os(tvOS)
			try audioSession.setCategory(.playAndRecord, options: [])
			#else
			try audioSession.setCategory(.playAndRecord, options: [.defaultToSpeaker])
			#endif
			try audioSession.setMode(.videoChat)
			try audioSession.setActive(true, options: .notifyOthersOnDeactivation)
		} catch {
			print("Failed to configure AVAudioSession: \(error)")
		}
		#endif
	}

	/// Parses the OpenAI-assigned Realtime call ID from the `Location` header
	/// returned by a successful `201` response to `POST /v1/realtime/calls`,
	/// e.g. `Location: /v1/realtime/calls/rtc_abc123` -> `"rtc_abc123"`.
	/// The header is a relative path, not an absolute URL — this takes the
	/// last non-empty `/`-separated path segment rather than assuming a
	/// scheme/host. Returns `nil` when the header is absent or has no
	/// non-empty segment; that should not happen on a well-formed `201` but
	/// is not treated as fatal here (see `fetchRemoteSDP`).
	static func providerCallId(fromLocationHeader header: String?) -> String? {
		guard let header,
		      let lastSegment = header.split(separator: "/").last,
		      !lastSegment.isEmpty
		else { return nil }
		return String(lastSegment)
	}

	func performHandshake(using request: URLRequest) async throws -> String? {
		let sdp = try await Result { try await connection.offer(for: LKRTCMediaConstraints(mandatoryConstraints: ["levelControl": "true"], optionalConstraints: nil)) }
			.mapError(WebRTCError.failedToCreateSDPOffer)
			.get()

		do { try await connection.setLocalDescription(sdp) }
		catch { throw WebRTCError.failedToSetLocalDescription(error) }

		let result = try await fetchRemoteSDP(using: request, localSdp: connection.localDescription!.sdp)

		do { try await connection.setRemoteDescription(LKRTCSessionDescription(type: .answer, sdp: result.remoteSdp)) }
		catch { throw WebRTCError.failedToSetRemoteDescription(error) }

		return result.providerCallId
	}

	/// Carries both outputs of `fetchRemoteSDP`: the SDP answer body needed to
	/// complete the WebRTC handshake, and the OpenAI-assigned Realtime call ID
	/// read from the `Location` response header. File-private — this never
	/// crosses the WebRTC module boundary; only `providerCallId` propagates
	/// further up via `performHandshake`'s return value.
	private struct RemoteSDPResult {
		let remoteSdp: String
		let providerCallId: String?
	}

	private func fetchRemoteSDP(using request: URLRequest, localSdp: String) async throws -> RemoteSDPResult {
		var request = request
		request.httpBody = localSdp.data(using: .utf8)
		request.setValue("application/sdp", forHTTPHeaderField: "Content-Type")

		let (data, response) = try await URLSession.shared.data(for: request)

		guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 201, let remoteSdp = String(data: data, encoding: .utf8) else {
			if (response as? HTTPURLResponse)?.statusCode == 401 { throw WebRTCError.invalidEphemeralKey }
			throw WebRTCError.badServerResponse(response)
		}

		let providerCallId = Self.providerCallId(fromLocationHeader: httpResponse.value(forHTTPHeaderField: "Location"))
		if providerCallId == nil {
			// Should not happen on a well-formed 201 from POST /v1/realtime/calls.
			// Capturing failure is distinct from an SDP-negotiation failure: the
			// handshake still succeeded, so we do not throw here. Callers must
			// treat a nil providerCallId as equivalent to a registration failure
			// once they reach the point of registering it with the Rishi backend.
			print("WebRTCConnector: OpenAI Realtime call response was missing/malformed Location header; provider call ID not captured for this call.")
		}

		return RemoteSDPResult(remoteSdp: remoteSdp, providerCallId: providerCallId)
	}
}

extension WebRTCConnector: LKRTCPeerConnectionDelegate {
	public func peerConnectionShouldNegotiate(_: LKRTCPeerConnection) {}
	public func peerConnection(_: LKRTCPeerConnection, didAdd _: LKRTCMediaStream) {}
	public func peerConnection(_: LKRTCPeerConnection, didOpen _: LKRTCDataChannel) {}
	public func peerConnection(_: LKRTCPeerConnection, didRemove _: LKRTCMediaStream) {}
	public func peerConnection(_: LKRTCPeerConnection, didChange _: LKRTCSignalingState) {}
	public func peerConnection(_: LKRTCPeerConnection, didGenerate _: LKRTCIceCandidate) {}
	public func peerConnection(_: LKRTCPeerConnection, didRemove _: [LKRTCIceCandidate]) {}
	public func peerConnection(_: LKRTCPeerConnection, didChange _: LKRTCIceGatheringState) {}

	public func peerConnection(_: LKRTCPeerConnection, didChange newState: LKRTCIceConnectionState) {
		print("ICE Connection State changed to: \(newState)")
	}
}

extension WebRTCConnector: LKRTCDataChannelDelegate {
	public func dataChannel(_: LKRTCDataChannel, didReceiveMessageWith buffer: LKRTCDataBuffer) {
		do { try stream.yield(decoder.decode(ServerEvent.self, from: buffer.data)) }
		catch {
			// Unknown/undecodable server event (e.g. a newer event type this
			// SDK version does not model, like `output_audio_buffer.cleared`).
			// Skip it and keep the stream alive — a single unrecognized event
			// must NOT tear down the whole conversation, or every later event
			// (tool-call arguments, responses, audio) is lost and the turn hangs.
			print("Skipping undecodable server event: \(String(data: buffer.data, encoding: .utf8) ?? "<invalid utf8>")")
		}
	}

	public func dataChannelDidChangeState(_ dataChannel: LKRTCDataChannel) {
		Task { @MainActor [state = dataChannel.readyState] in
			switch state {
				case .open:
					status = .connected
					statusStream.yield(.connected)
				case .closing, .closed:
					status = .disconnected
					statusStream.yield(.disconnected)
				default: break
			}
		}
	}
}
