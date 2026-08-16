@preconcurrency import CoreSpotlight
import Foundation
import UniformTypeIdentifiers

enum RishiSpotlightURL {
    static func book(_ id: BookID) -> URL {
        URL(string: "https://rishi.fidexa.org/app/book/\(id.uuidString)")!
    }

    static func conversation(_ id: ConversationID) -> URL {
        URL(string: "https://rishi.fidexa.org/app/conversation/\(id.uuidString)")!
    }
}

struct RishiSpotlightDescriptor: Sendable, Equatable {
    let uniqueIdentifier: String
    let domainIdentifier: String
    let title: String
    let contentDescription: String
    let keywords: [String]
    let url: URL
    let contentTypeIdentifier: String

    static func book(_ book: Book) -> Self {
        var keywords = [book.title]
        if let author = book.author, !author.isEmpty { keywords.append(author) }
        keywords.append(book.formatType.rawValue)
        return Self(
            uniqueIdentifier: "book:\(book.id.uuidString)",
            domainIdentifier: domain(for: book.userId),
            title: book.title,
            contentDescription: [book.author, book.formatType.rawValue.capitalized]
                .compactMap { $0 }
                .joined(separator: " · "),
            keywords: keywords,
            url: RishiSpotlightURL.book(book.id),
            contentTypeIdentifier: UTType.text.identifier
        )
    }

    static func highlight(_ highlight: Highlight, book: Book) -> Self {
        let description = [book.title, highlight.text, highlight.note]
            .compactMap { $0 }
            .joined(separator: "\n")
        var keywords = [book.title, highlight.text]
        if let note = highlight.note, !note.isEmpty { keywords.append(note) }
        return Self(
            uniqueIdentifier: "highlight:\(highlight.id.uuidString)",
            domainIdentifier: domain(for: book.userId),
            title: book.title,
            contentDescription: description,
            keywords: keywords,
            url: RishiSpotlightURL.book(book.id),
            contentTypeIdentifier: UTType.text.identifier
        )
    }

    static func conversation(_ conversation: Conversation) -> Self {
        Self(
            uniqueIdentifier: "conversation:\(conversation.id.uuidString)",
            domainIdentifier: domain(for: conversation.userId),
            title: conversation.title,
            contentDescription: conversation.title,
            keywords: [conversation.title],
            url: RishiSpotlightURL.conversation(conversation.id),
            contentTypeIdentifier: UTType.text.identifier
        )
    }

    private static func domain(for userID: UserID) -> String {
        "user:\(userID.uuidString)"
    }
}

protocol RishiSearchIndexingClient: Sendable {
    func deleteAll() async throws
    func delete(domainIdentifiers: [String]) async throws
    func index(_ descriptors: [RishiSpotlightDescriptor]) async throws
}

final class RishiCoreSpotlightIndexingClient: RishiSearchIndexingClient, @unchecked Sendable {
    static let indexName = "org.fidexa.rishi.spotlight"

    private let index: CSSearchableIndex

    init() {
        index = CSSearchableIndex(name: Self.indexName)
    }

    func deleteAll() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            index.deleteAllSearchableItems { error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            }
        }
    }

    func delete(domainIdentifiers: [String]) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            index.deleteSearchableItems(withDomainIdentifiers: domainIdentifiers) { error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            }
        }
    }

    func index(_ descriptors: [RishiSpotlightDescriptor]) async throws {
        let items = descriptors.map { descriptor in
            let attributes = CSSearchableItemAttributeSet(
                itemContentType: descriptor.contentTypeIdentifier
            )
            attributes.title = descriptor.title
            attributes.contentDescription = descriptor.contentDescription
            attributes.keywords = descriptor.keywords
            attributes.contentURL = descriptor.url
            return CSSearchableItem(
                uniqueIdentifier: descriptor.uniqueIdentifier,
                domainIdentifier: descriptor.domainIdentifier,
                attributeSet: attributes
            )
        }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            index.indexSearchableItems(items) { error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            }
        }
    }
}
