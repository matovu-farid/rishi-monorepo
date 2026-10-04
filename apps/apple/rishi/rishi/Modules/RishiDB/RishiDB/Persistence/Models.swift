import Foundation
import SwiftData


enum RishiDBModelTypes {
    static let all: [any PersistentModel.Type] = [
        BookEntity.self,
        PositionEntity.self,
        HighlightEntity.self,
        BookmarkEntity.self,
        ConversationEntity.self,
        MessageEntity.self,
        UserEntity.self,
        SyncMetadataEntity.self,
        ChapterIndexEntity.self,
        ChapterSummaryEntity.self,
        BookFileFingerprintEntity.self,
        PendingBookMaterializationEntity.self,
        BookReadingAuthorizationEntity.self,
        AccountMutationAuthorizationEntity.self,
    ]
}

@Model
final class BookFileFingerprintEntity {
    @Attribute(.unique) var bookID: UUID
    var ownerID: UUID
    var sha256: String
    var byteCount: Int64
    var modificationDate: Date
    var fileIdentifier: String?
    var materializationRevision: UUID
    var serverAcceptanceSHA256: String?
    var acceptedOperationID: UUID?
    var acceptedAt: Date?

    init(_ value: BookFileFingerprint) {
        bookID = value.bookID
        ownerID = value.ownerID
        sha256 = value.sha256
        byteCount = value.version.byteCount
        modificationDate = value.version.modificationDate
        fileIdentifier = value.version.fileIdentifier
        materializationRevision = value.version.materializationRevision
        serverAcceptanceSHA256 = value.serverAcceptance?.sha256
        acceptedOperationID = value.serverAcceptance?.acceptedOperationID
        acceptedAt = value.serverAcceptance?.acceptedAt
    }

    var value: BookFileFingerprint {
        let acceptance: BookServerAcceptance?
        if let sha = serverAcceptanceSHA256, let operationID = acceptedOperationID, let acceptedAt {
            acceptance = BookServerAcceptance(sha256: sha, acceptedOperationID: operationID, acceptedAt: acceptedAt)
        } else {
            acceptance = nil
        }
        return BookFileFingerprint(
            bookID: bookID,
            ownerID: ownerID,
            sha256: sha256,
            version: ManagedFileVersion(byteCount: byteCount, modificationDate: modificationDate, fileIdentifier: fileIdentifier, materializationRevision: materializationRevision),
            serverAcceptance: acceptance
        )
    }
}

@Model
final class PendingBookMaterializationEntity {
    @Attribute(.unique) var bookID: UUID
    var ownerID: UUID
    var accountGenerationBits: Int64
    var attemptID: UUID
    var sourceKindRawValue: String
    var sourceBookmark: Data?
    var ownedSourceRelativePath: String?
    var sourceByteCount: Int64
    var sourceModificationDate: Date
    var sourceFileIdentifier: String?
    var sourceMaterializationRevision: UUID
    var expectedSHA256: String
    var expectedByteCount: Int64
    var stagingRelativePath: String
    var destinationRelativePath: String
    var phaseRawValue: String
    var retryableErrorCode: String?
    var preparedFileIdentifier: String?
    var destinationFileIdentifier: String?
    var promotionRevision: UUID?

    init(_ value: PendingBookMaterialization) {
        bookID = value.token.bookID
        ownerID = value.token.ownerID
        accountGenerationBits = Int64(bitPattern: value.token.accountGeneration)
        attemptID = value.token.attemptID
        sourceKindRawValue = value.sourceKind.rawValue
        sourceBookmark = value.sourceBookmark
        ownedSourceRelativePath = value.ownedSourceRelativePath
        sourceByteCount = value.sourceVersion.byteCount
        sourceModificationDate = value.sourceVersion.modificationDate
        sourceFileIdentifier = value.sourceVersion.fileIdentifier
        sourceMaterializationRevision = value.sourceVersion.materializationRevision
        expectedSHA256 = value.expectedSHA256
        expectedByteCount = value.expectedByteCount
        stagingRelativePath = value.stagingRelativePath
        destinationRelativePath = value.destinationRelativePath
        phaseRawValue = value.phase.rawValue
        retryableErrorCode = value.retryableErrorCode
        preparedFileIdentifier = value.preparedFileIdentifier
        destinationFileIdentifier = value.destinationFileIdentifier
        promotionRevision = value.promotionRevision
    }

    var value: PendingBookMaterialization? {
        guard let sourceKind = BookSourceKind(rawValue: sourceKindRawValue),
              let phase = BookMaterializationPhase(rawValue: phaseRawValue) else { return nil }
        return PendingBookMaterialization(
            token: BookMaterializationToken(ownerID: ownerID, accountGeneration: UInt64(bitPattern: accountGenerationBits), bookID: bookID, attemptID: attemptID),
            sourceKind: sourceKind,
            sourceBookmark: sourceBookmark,
            ownedSourceRelativePath: ownedSourceRelativePath,
            sourceVersion: ManagedFileVersion(byteCount: sourceByteCount, modificationDate: sourceModificationDate, fileIdentifier: sourceFileIdentifier, materializationRevision: sourceMaterializationRevision),
            expectedSHA256: expectedSHA256,
            expectedByteCount: expectedByteCount,
            stagingRelativePath: stagingRelativePath,
            destinationRelativePath: destinationRelativePath,
            phase: phase,
            retryableErrorCode: retryableErrorCode,
            preparedFileIdentifier: preparedFileIdentifier,
            destinationFileIdentifier: destinationFileIdentifier,
            promotionRevision: promotionRevision
        )
    }
}

@Model
final class BookReadingAuthorizationEntity {
    @Attribute(.unique) var bookID: UUID
    var ownerID: UUID
    var accountGenerationBits: Int64
    var contentRevision: UUID
    var verifiedContentDigest: String?
    var revoked: Bool
    var tombstoned: Bool

    init(bookID: UUID, ownerID: UUID, generation: UInt64, contentRevision: UUID, verifiedContentDigest: String? = nil, revoked: Bool = false, tombstoned: Bool) {
        self.bookID = bookID
        self.ownerID = ownerID
        accountGenerationBits = Int64(bitPattern: generation)
        self.contentRevision = contentRevision
        self.verifiedContentDigest = verifiedContentDigest
        self.revoked = revoked
        self.tombstoned = tombstoned
    }
}

@Model
final class AccountMutationAuthorizationEntity {
    @Attribute(.unique) var ownerID: UUID
    var accountGenerationBits: Int64
    var revoked: Bool

    init(ownerID: UUID, generation: UInt64, revoked: Bool = false) {
        self.ownerID = ownerID
        accountGenerationBits = Int64(bitPattern: generation)
        self.revoked = revoked
    }
}

@Model
final class BookEntity {
    @Attribute(.unique) var id: UUID
    var userId: UUID
    var title: String
    var author: String?
    var formatTypeRawValue: String
    var addedAt: Date
    var openedAt: Date?
    var fileURL: String
    var coverPath: String?
    var positionId: UUID?
    var conversationId: UUID?
    var chapterIndexContentVersion: String?

    init(
        id: UUID,
        userId: UUID,
        title: String,
        author: String?,
        formatTypeRawValue: String,
        addedAt: Date,
        openedAt: Date?,
        fileURL: String,
        coverPath: String?,
        positionId: UUID?,
        conversationId: UUID?,
        chapterIndexContentVersion: String? = nil
    ) {
        self.id = id
        self.userId = userId
        self.title = title
        self.author = author
        self.formatTypeRawValue = formatTypeRawValue
        self.addedAt = addedAt
        self.openedAt = openedAt
        self.fileURL = fileURL
        self.coverPath = coverPath
        self.positionId = positionId
        self.conversationId = conversationId
        self.chapterIndexContentVersion = chapterIndexContentVersion
    }

    var bookValue: Book? {
        guard let formatType = BookFormat(rawValue: formatTypeRawValue) else { return nil }
        return Book(
            id: id,
            userId: userId,
            title: title,
            author: author,
            formatType: formatType,
            addedAt: addedAt,
            openedAt: openedAt,
            fileURL: fileURL,
            coverPath: coverPath,
            positionId: positionId,
            conversationId: conversationId,
            chapterIndexContentVersion: chapterIndexContentVersion
        )
    }

    func update(from book: Book) {
        userId = book.userId
        title = book.title
        author = book.author
        formatTypeRawValue = book.formatType.rawValue
        addedAt = book.addedAt
        openedAt = book.openedAt
        fileURL = book.fileURL
        coverPath = book.coverPath
        positionId = book.positionId
        conversationId = book.conversationId
        chapterIndexContentVersion = book.chapterIndexContentVersion
    }
}

@Model
final class ChapterIndexEntity {
    @Attribute(.unique) var id: UUID
    var bookID: UUID
    var contentVersion: String
    var statusRawValue: String
    var modelIdentifier: String
    var modelVersion: String
    var completedCount: Int
    var totalCount: Int
    var errorMessage: String?
    var createdAt: Date
    var updatedAt: Date

    init(id: UUID, bookID: UUID, contentVersion: String, statusRawValue: String, modelIdentifier: String, modelVersion: String, completedCount: Int, totalCount: Int, errorMessage: String?, createdAt: Date, updatedAt: Date) {
        self.id = id; self.bookID = bookID; self.contentVersion = contentVersion
        self.statusRawValue = statusRawValue; self.modelIdentifier = modelIdentifier; self.modelVersion = modelVersion
        self.completedCount = completedCount; self.totalCount = totalCount; self.errorMessage = errorMessage
        self.createdAt = createdAt; self.updatedAt = updatedAt
    }
}

@Model
final class ChapterSummaryEntity {
    @Attribute(.unique) var id: UUID
    var indexID: UUID
    var chapterID: String
    var name: String
    var summary: String
    /// Optional keeps existing SwiftData stores lightweight-migration-safe.
    var sourcePosition: Int?
    var createdAt: Date
    var updatedAt: Date

    init(id: UUID, indexID: UUID, chapterID: String, name: String, summary: String, sourcePosition: Int? = nil, createdAt: Date, updatedAt: Date) {
        self.id = id; self.indexID = indexID; self.chapterID = chapterID; self.name = name; self.summary = summary
        self.sourcePosition = sourcePosition
        self.createdAt = createdAt; self.updatedAt = updatedAt
    }
}

@Model
final class PositionEntity {
    @Attribute(.unique) var id: UUID
    var bookId: UUID
    var locator: String
    var percentComplete: Double
    var updatedAt: Date

    init(id: UUID, bookId: UUID, locator: String, percentComplete: Double, updatedAt: Date) {
        self.id = id
        self.bookId = bookId
        self.locator = locator
        self.percentComplete = percentComplete
        self.updatedAt = updatedAt
    }

    var positionValue: Position? {
        Position(
            id: id,
            bookId: bookId,
            locator: locator,
            percentComplete: percentComplete,
            updatedAt: updatedAt
        )
    }

    func update(from position: Position) {
        bookId = position.bookId
        locator = position.locator
        percentComplete = position.percentComplete
        updatedAt = position.updatedAt
    }
}

@Model
final class HighlightEntity {
    @Attribute(.unique) var id: UUID
    var bookId: UUID
    var locatorStart: String
    var locatorEnd: String
    var colorRawValue: String
    var text: String
    var note: String?
    var createdAt: Date

    init(
        id: UUID,
        bookId: UUID,
        locatorStart: String,
        locatorEnd: String,
        colorRawValue: String,
        text: String,
        note: String?,
        createdAt: Date
    ) {
        self.id = id
        self.bookId = bookId
        self.locatorStart = locatorStart
        self.locatorEnd = locatorEnd
        self.colorRawValue = colorRawValue
        self.text = text
        self.note = note
        self.createdAt = createdAt
    }

    var highlightValue: Highlight? {
        guard let color = HighlightColor(rawValue: colorRawValue) else { return nil }
        return Highlight(
            id: id,
            bookId: bookId,
            locatorStart: locatorStart,
            locatorEnd: locatorEnd,
            color: color,
            text: text,
            note: note,
            createdAt: createdAt
        )
    }

    func update(from highlight: Highlight) {
        bookId = highlight.bookId
        locatorStart = highlight.locatorStart
        locatorEnd = highlight.locatorEnd
        colorRawValue = highlight.color.rawValue
        text = highlight.text
        note = highlight.note
        createdAt = highlight.createdAt
    }
}

@Model
final class BookmarkEntity {
    @Attribute(.unique) var id: UUID
    var bookId: UUID
    var locator: String
    var label: String?
    var snippet: String?
    var createdAt: Date

    init(id: UUID, bookId: UUID, locator: String, label: String?, snippet: String?, createdAt: Date) {
        self.id = id
        self.bookId = bookId
        self.locator = locator
        self.label = label
        self.snippet = snippet
        self.createdAt = createdAt
    }

    var bookmarkValue: Bookmark {
        Bookmark(
            id: id,
            bookId: bookId,
            locator: locator,
            label: label,
            snippet: snippet,
            createdAt: createdAt
        )
    }

    func update(from bookmark: Bookmark) {
        bookId = bookmark.bookId
        locator = bookmark.locator
        label = bookmark.label
        snippet = bookmark.snippet
        createdAt = bookmark.createdAt
    }
}

@Model
final class ConversationEntity {
    @Attribute(.unique) var id: UUID
    var userId: UUID
    var bookId: UUID?
    var title: String
    var createdAt: Date
    var updatedAt: Date

    init(id: UUID, userId: UUID, bookId: UUID?, title: String, createdAt: Date, updatedAt: Date) {
        self.id = id
        self.userId = userId
        self.bookId = bookId
        self.title = title
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    var conversationValue: Conversation {
        Conversation(
            id: id,
            userId: userId,
            bookId: bookId,
            title: title,
            createdAt: createdAt,
            updatedAt: updatedAt
        )
    }

    func update(from conversation: Conversation) {
        userId = conversation.userId
        bookId = conversation.bookId
        title = conversation.title
        createdAt = conversation.createdAt
        updatedAt = conversation.updatedAt
    }
}

@Model
final class MessageEntity {
    @Attribute(.unique) var id: UUID
    var conversationId: UUID
    var roleRawValue: String
    var content: String
    var toolCalls: String?
    var createdAt: Date

    init(
        id: UUID,
        conversationId: UUID,
        roleRawValue: String,
        content: String,
        toolCalls: String?,
        createdAt: Date
    ) {
        self.id = id
        self.conversationId = conversationId
        self.roleRawValue = roleRawValue
        self.content = content
        self.toolCalls = toolCalls
        self.createdAt = createdAt
    }

    var messageValue: Message? {
        guard let role = MessageRole(rawValue: roleRawValue) else { return nil }
        return Message(
            id: id,
            conversationId: conversationId,
            role: role,
            content: content,
            toolCalls: toolCalls,
            createdAt: createdAt
        )
    }

    func update(from message: Message) {
        conversationId = message.conversationId
        roleRawValue = message.role.rawValue
        content = message.content
        toolCalls = message.toolCalls
        createdAt = message.createdAt
    }
}

@Model
final class UserEntity {
    @Attribute(.unique) var id: UUID
    var email: String
    var displayName: String?
    var avatarURL: String?
    var hasPro: Bool
    var createdAt: Date

    init(
        id: UUID,
        email: String,
        displayName: String?,
        avatarURL: String?,
        hasPro: Bool,
        createdAt: Date
    ) {
        self.id = id
        self.email = email
        self.displayName = displayName
        self.avatarURL = avatarURL
        self.hasPro = hasPro
        self.createdAt = createdAt
    }
}

@Model
final class SyncMetadataEntity {
    @Attribute(.unique) var entityId: UUID
    var entityType: String
    var remoteEtag: String?
    var lastSyncedAt: Date?
    var dirty: Bool

    init(
        entityId: UUID,
        entityType: String,
        remoteEtag: String?,
        lastSyncedAt: Date?,
        dirty: Bool
    ) {
        self.entityId = entityId
        self.entityType = entityType
        self.remoteEtag = remoteEtag
        self.lastSyncedAt = lastSyncedAt
        self.dirty = dirty
    }
}
