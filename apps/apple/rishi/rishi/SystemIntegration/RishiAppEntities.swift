import AppIntents
import Foundation

struct RishiBookEntity: AppEntity, Hashable {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Book")
    static let defaultQuery = RishiBookEntityQuery()

    let id: UUID

    @Property(title: "Title")
    var title: String

    @Property(title: "Author")
    var author: String?

    init(id: UUID, title: String, author: String? = nil) {
        self.id = id
        self.title = title
        self.author = author
    }

    var displayRepresentation: DisplayRepresentation {
        if let author, !author.isEmpty {
            return DisplayRepresentation(
                title: LocalizedStringResource(stringLiteral: title),
                subtitle: LocalizedStringResource(stringLiteral: author)
            )
        }
        return DisplayRepresentation(title: LocalizedStringResource(stringLiteral: title))
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.id == rhs.id && lhs.title == rhs.title && lhs.author == rhs.author
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
        hasher.combine(title)
        hasher.combine(author)
    }
}

struct RishiConversationEntity: AppEntity, Hashable {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Conversation")
    static let defaultQuery = RishiConversationEntityQuery()

    let id: UUID

    @Property(title: "Title")
    var title: String

    init(id: UUID, title: String) {
        self.id = id
        self.title = title
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: LocalizedStringResource(stringLiteral: title))
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.id == rhs.id && lhs.title == rhs.title
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
        hasher.combine(title)
    }
}

struct RishiBookEntityQuery: EntityStringQuery {
    typealias Entity = RishiBookEntity

    private let loadByIDs: @Sendable ([UUID]) async throws -> [RishiBookEntity]
    private let loadAll: @Sendable () async throws -> [RishiBookEntity]

    init(
        loadByIDs: @escaping @Sendable ([UUID]) async throws -> [RishiBookEntity],
        loadAll: @escaping @Sendable () async throws -> [RishiBookEntity] = RishiAppIntentRuntime.loadBooks
    ) {
        self.loadByIDs = loadByIDs
        self.loadAll = loadAll
    }

    init() {
        self.init(
            loadByIDs: { ids in try await RishiAppIntentRuntime.loadBooks(ids: ids) },
            loadAll: RishiAppIntentRuntime.loadBooks
        )
    }

    func entities(for identifiers: [UUID]) async throws -> [RishiBookEntity] {
        try await loadByIDs(identifiers)
    }

    func suggestedEntities() async throws -> [RishiBookEntity] {
        try await loadAll()
    }

    func entities(matching string: String) async throws -> [RishiBookEntity] {
        let query = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return try await loadAll() }
        let entities = try await loadAll()
        return entities.filter { entity in
            entity.title.localizedCaseInsensitiveContains(query)
                || (entity.author?.localizedCaseInsensitiveContains(query) ?? false)
        }
    }
}

struct RishiConversationEntityQuery: EntityStringQuery {
    typealias Entity = RishiConversationEntity

    private let loadByIDs: @Sendable ([UUID]) async throws -> [RishiConversationEntity]
    private let loadAll: @Sendable () async throws -> [RishiConversationEntity]

    init(
        loadByIDs: @escaping @Sendable ([UUID]) async throws -> [RishiConversationEntity],
        loadAll: @escaping @Sendable () async throws -> [RishiConversationEntity] = RishiAppIntentRuntime.loadConversations
    ) {
        self.loadByIDs = loadByIDs
        self.loadAll = loadAll
    }

    init() {
        self.init(
            loadByIDs: { ids in try await RishiAppIntentRuntime.loadConversations(ids: ids) },
            loadAll: RishiAppIntentRuntime.loadConversations
        )
    }

    func entities(for identifiers: [UUID]) async throws -> [RishiConversationEntity] {
        try await loadByIDs(identifiers)
    }

    func suggestedEntities() async throws -> [RishiConversationEntity] {
        try await loadAll()
    }

    func entities(matching string: String) async throws -> [RishiConversationEntity] {
        let query = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return try await loadAll() }
        return try await loadAll().filter {
            $0.title.localizedCaseInsensitiveContains(query)
        }
    }
}
