import CryptoKit
import Foundation

public enum RealBookFormat: String, Codable, Sendable, Equatable {
    case pdf
    case epub
}

public enum RealBookFixtureError: Error, LocalizedError, Equatable {
    case missingEnvironmentVariable(String)
    case missingFile(URL)
    case notRegularFile(URL)
    case fileTooLarge(URL)
    case unsupportedExtension(String)
    case signatureMismatch(expected: RealBookFormat)

    public var errorDescription: String? {
        switch self {
        case .missingEnvironmentVariable(let key): return "Missing fixture environment variable \(key)."
        case .missingFile(let url): return "Fixture file does not exist: \(url.lastPathComponent)."
        case .notRegularFile(let url): return "Fixture is not a regular file: \(url.lastPathComponent)."
        case .fileTooLarge(let url): return "Fixture is too large: \(url.lastPathComponent)."
        case .unsupportedExtension(let ext): return "Unsupported fixture extension: \(ext)."
        case .signatureMismatch(let expected): return "Fixture signature does not match \(expected.rawValue)."
        }
    }
}

public struct RealBookFixture: Sendable, Equatable {
    public struct Manifest: Codable, Sendable, Equatable {
        public let role: TestAccountRole
        public let format: RealBookFormat
        public let basename: String
        public let sha256: String
        public let byteSize: Int64

        public init(role: TestAccountRole, format: RealBookFormat, basename: String, sha256: String, byteSize: Int64) {
            self.role = role
            self.format = format
            self.basename = basename
            self.sha256 = sha256
            self.byteSize = byteSize
        }
    }

    public let sourceURL: URL
    public let manifest: Manifest

    public var manifestJSON: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = (try? encoder.encode(manifest)) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }
}

public enum RealBookFixtures {
    public static let pdfEnvironmentKey = "RISHI_E2E_PDF_FIXTURE"
    public static let epubEnvironmentKey = "RISHI_E2E_EPUB_FIXTURE"
    public static let maxFixtureBytes: Int64 = 512 * 1024 * 1024

    public static func resolve(
        role: TestAccountRole,
        format: RealBookFormat? = nil,
        path: URL? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> RealBookFixture {
        let requestedFormat = try format ?? inferFormat(path: path)
        let sourceURL: URL
        if let path {
            sourceURL = path
        } else {
            let key = requestedFormat == .pdf ? pdfEnvironmentKey : epubEnvironmentKey
            guard let configuredPath = environment[key], !configuredPath.isEmpty else {
                throw RealBookFixtureError.missingEnvironmentVariable(key)
            }
            sourceURL = URL(fileURLWithPath: configuredPath)
        }

        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: sourceURL.path) else {
            throw RealBookFixtureError.missingFile(sourceURL)
        }
        guard let attributes = try? fileManager.attributesOfItem(atPath: sourceURL.path),
              (attributes[.type] as? FileAttributeType) == .typeRegular else {
            throw RealBookFixtureError.notRegularFile(sourceURL)
        }
        guard let fileSize = (attributes[.size] as? NSNumber)?.int64Value,
              fileSize <= maxFixtureBytes else {
            throw RealBookFixtureError.fileTooLarge(sourceURL)
        }

        let actualFormat = try inferFormat(path: sourceURL)
        guard actualFormat == requestedFormat else {
            throw RealBookFixtureError.signatureMismatch(expected: requestedFormat)
        }
        let handle = try FileHandle(forReadingFrom: sourceURL)
        defer { try? handle.close() }
        let header = try handle.read(upToCount: 8) ?? Data()
        guard hasSignature(header, format: actualFormat) else {
            throw RealBookFixtureError.signatureMismatch(expected: actualFormat)
        }
        try handle.seek(toOffset: 0)
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1024 * 1024), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        let hash = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        let manifest = RealBookFixture.Manifest(
            role: role,
            format: actualFormat,
            basename: sourceURL.lastPathComponent,
            sha256: hash,
            byteSize: fileSize
        )
        return RealBookFixture(sourceURL: sourceURL.standardizedFileURL, manifest: manifest)
    }

    private static func inferFormat(path: URL?) throws -> RealBookFormat {
        guard let path else {
            throw RealBookFixtureError.missingEnvironmentVariable("RISHI_E2E_*_FIXTURE")
        }
        let extensionName = path.pathExtension.lowercased()
        guard let format = RealBookFormat(rawValue: extensionName) else {
            throw RealBookFixtureError.unsupportedExtension(extensionName)
        }
        return format
    }

    private static func hasSignature(_ data: Data, format: RealBookFormat) -> Bool {
        switch format {
        case .pdf:
            return data.starts(with: Data("%PDF-".utf8))
        case .epub:
            guard data.count >= 4 else { return false }
            let bytes = Array(data.prefix(4))
            return bytes == [0x50, 0x4B, 0x03, 0x04] || bytes == [0x50, 0x4B, 0x05, 0x06] || bytes == [0x50, 0x4B, 0x07, 0x08]
        }
    }
}
