import Foundation



struct BookImporter: Sendable {
    private let rootURL: URL
    private let booksDirURL: URL
    private let bookStore: any BookStore
    private let coverExtractors: [String: any CoverExtractor]
    private let metadataExtractors: [String: any MetadataExtractor]
    private let bookIndexingHook: any BookIndexingHook

    private var fileManager: FileManager { .default }

    init(
        rootURL: URL,
        booksDirURL: URL,
        bookStore: any BookStore,
        coverExtractors: [String: any CoverExtractor],
        metadataExtractors: [String: any MetadataExtractor],
        bookIndexingHook: any BookIndexingHook
    ) {
        self.rootURL = rootURL
        self.booksDirURL = booksDirURL
        self.bookStore = bookStore
        self.coverExtractors = coverExtractors
        self.metadataExtractors = metadataExtractors
        self.bookIndexingHook = bookIndexingHook
    }

    func importBook(from sourceURL: URL, ownerId: UserID) async throws -> Book {
        try ensureBooksDirExists()

        let ext = sourceURL.pathExtension.lowercased()
        guard let format = BookFormat(rawValue: ext) else {
            throw BookFileStorage.StorageError.unsupportedFormat(ext: ext)
        }

        var metadata = BookMetadata()
        if let extractor = metadataExtractors[ext] {
            metadata = await extractor.extractMetadata(from: sourceURL)
        }

        let bookId =
            DeterministicBookID.make(
                title: metadata.title,
                author: metadata.author,
                format: format
            ) ?? UUID()
        let bookDir = booksDirURL.appendingPathComponent(
            bookId.uuidString,
            isDirectory: true
        )
        try fileManager.createDirectory(
            at: bookDir,
            withIntermediateDirectories: true
        )

        let filename = sourceURL.lastPathComponent
        let destURL = bookDir.appendingPathComponent(filename)

        if fileManager.fileExists(atPath: destURL.path) {
            try? fileManager.removeItem(at: destURL)
        }
        do {
            try fileManager.copyItem(at: sourceURL, to: destURL)
        } catch {
            throw BookFileStorage.StorageError.copyFailed(underlying: error)
        }

        var coverPath: String?
        if let extractor = coverExtractors[ext] {
            if let png = await extractor.extractCover(from: destURL) {
                let coverURL = bookDir.appendingPathComponent("cover.png")
                do {
                    try png.write(to: coverURL, options: .atomic)
                    coverPath = relativePath(of: coverURL)
                } catch {
                    Log.event(
                        "cover.write.failed",
                        level: .info,
                        data: [
                            "book": bookId.uuidString,
                            "error": String(describing: error),
                        ]
                    )
                }
            }
        }

        let book = Book(
            id: bookId,
            userId: ownerId,
            title: metadata.title ?? titleFallback(from: filename),
            author: metadata.author,
            formatType: format,
            addedAt: Date(),
            openedAt: nil,
            fileURL: relativePath(of: destURL),
            coverPath: coverPath
        )
        try await bookStore.upsert(book)

        await bookIndexingHook.scheduleIndexing(for: book, fileURL: destURL)
        return book
    }

    private func ensureBooksDirExists() throws {
        if !fileManager.fileExists(atPath: booksDirURL.path) {
            try fileManager.createDirectory(
                at: booksDirURL,
                withIntermediateDirectories: true
            )
        }
    }

    private func relativePath(of url: URL) -> String {
        let root = rootURL.standardizedFileURL.path
        let target = url.standardizedFileURL.path
        if target.hasPrefix(root + "/") {
            return String(target.dropFirst(root.count + 1))
        }
        return target
    }

    private func titleFallback(from filename: String) -> String {
        let nameOnly = (filename as NSString).deletingPathExtension
        let withSpaces = nameOnly.replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
        return withSpaces.isEmpty ? "Untitled" : withSpaces
    }
}
