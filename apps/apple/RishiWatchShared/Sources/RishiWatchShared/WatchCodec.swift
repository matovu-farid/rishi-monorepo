import Foundation

public enum WatchCodecError: Error, Equatable {
    case unsupportedVersion
    case staleCommand
    case staleSequence
    case invalidPayload
    case capacityExceeded
}

public enum WatchCodec {
    public static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(value)
    }

    public static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let value = try decoder.decode(type, from: data)
        if let versioned = value as? any WatchVersioned,
           versioned.protocolVersion != WatchProtocolConstants.currentVersion {
            throw WatchCodecError.unsupportedVersion
        }
        return value
    }

    public static func isFresh(_ envelope: WatchMutatingCommandEnvelope, now: Date = Date()) -> Bool {
        now.timeIntervalSince(envelope.issuedAt) <= WatchProtocolConstants.commandLifetime
            && envelope.issuedAt.timeIntervalSince(now) <= 5
    }
}
