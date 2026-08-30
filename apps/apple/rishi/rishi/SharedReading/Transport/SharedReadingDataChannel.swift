import Foundation
@preconcurrency import LiveKitWebRTC

final class SharedReadingDataChannel: NSObject, @unchecked Sendable {
    enum State: Sendable, Equatable {
        case connecting
        case open
        case closing
        case closed
    }

    enum Event: Sendable, Equatable {
        case state(State)
        case data(Data, isBinary: Bool)
    }

    let remoteUserId: String
    let events: AsyncStream<Event>

    private let channel: LKRTCDataChannel
    private let continuation: AsyncStream<Event>.Continuation

    init(channel: LKRTCDataChannel, remoteUserId: String) {
        self.channel = channel
        self.remoteUserId = remoteUserId

        var continuation: AsyncStream<Event>.Continuation!
        self.events = AsyncStream { continuation = $0 }
        self.continuation = continuation

        super.init()
        channel.delegate = self
        continuation.yield(.state(Self.state(for: channel.readyState)))
    }

    var isOpen: Bool {
        channel.readyState == .open
    }

    @discardableResult
    func send(_ data: Data, isBinary: Bool = true) -> Bool {
        guard channel.readyState == .open else { return false }
        return channel.sendData(LKRTCDataBuffer(data: data, isBinary: isBinary))
    }

    @discardableResult
    func sendData(_ data: Data, isBinary: Bool = true) -> Bool {
        send(data, isBinary: isBinary)
    }

    @discardableResult
    func send(string: String) -> Bool {
        send(Data(string.utf8), isBinary: false)
    }

    func close() {
        channel.close()
    }

    private static func state(for state: LKRTCDataChannelState) -> State {
        switch state {
        case .connecting: return .connecting
        case .open: return .open
        case .closing: return .closing
        case .closed: return .closed
        @unknown default: return .closed
        }
    }
}

extension SharedReadingDataChannel: LKRTCDataChannelDelegate {
    func dataChannelDidChangeState(_ dataChannel: LKRTCDataChannel) {
        let state = Self.state(for: dataChannel.readyState)
        continuation.yield(.state(state))
        if state == .closed {
            continuation.finish()
        }
    }

    func dataChannel(_: LKRTCDataChannel, didReceiveMessageWith buffer: LKRTCDataBuffer) {
        continuation.yield(.data(buffer.data, isBinary: buffer.isBinary))
    }
}
