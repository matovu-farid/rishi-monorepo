@testable import rishi
import Foundation
import SwiftData
import Testing


@Suite("RishiDB auxiliary models")
struct MigrationsTests {

    @Test func userAndSyncMetadataPersist() throws {
        let container = try RishiDB.makeModelContainer(at: URL(fileURLWithPath: ":memory:"))
        let context = ModelContext(container)

        let user = UserEntity(
            id: UUID(),
            email: "test@example.com",
            displayName: "Test",
            avatarURL: "https://example.com/avatar.jpg",
            hasPro: true,
            createdAt: .now
        )
        let metadata = SyncMetadataEntity(
            entityId: UUID(),
            entityType: "book",
            remoteEtag: "etag-1",
            lastSyncedAt: .now,
            dirty: false
        )

        context.insert(user)
        context.insert(metadata)
        try context.save()

        let fetchedUser: [UserEntity] = try context.fetch(FetchDescriptor<UserEntity>())
        #expect(fetchedUser.first?.email == "test@example.com")
        #expect(fetchedUser.first?.hasPro == true)

        let fetchedMetadata: [SyncMetadataEntity] = try context.fetch(FetchDescriptor<SyncMetadataEntity>())
        #expect(fetchedMetadata.first?.entityType == "book")
        #expect(fetchedMetadata.first?.dirty == false)
    }
}
