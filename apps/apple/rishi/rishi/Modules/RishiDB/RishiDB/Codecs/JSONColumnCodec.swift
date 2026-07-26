import Foundation

/// Encode/decode arbitrary Codable values for storage in opaque TEXT columns
/// (e.g. messages.tool_calls). Returning a `String` keeps the column type
/// consistent with the v1 migration schema (`TEXT`).
enum JSONColumnCodec {
    static func encode<T: Encodable>(_ value: T) throws -> String {
        let data = try JSONEncoder().encode(value)
        guard let str = String(data: data, encoding: .utf8) else {
            throw NSError(domain: "JSONColumnCodec", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "non-utf8 encoded data"])
        }
        return str
    }

    static func decode<T: Decodable>(_ string: String?) throws -> T? {
        guard let string, !string.isEmpty else { return nil }
        return try JSONDecoder().decode(T.self, from: Data(string.utf8))
    }
}
