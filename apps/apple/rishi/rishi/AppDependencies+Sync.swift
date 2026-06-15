import Foundation
import RishiSync
import RishiDB

// MARK: - Sync forwarder accessors

extension AppDependencies {
    var syncMetadataStore: GRDBSyncMetadataStore { services!.syncMetadataStore }
    var syncQueue: SyncQueue { services!.syncQueue }
    var syncStatus: SyncStatus { services!.syncStatus }
    var bookUploader: BookUploader { services!.bookUploader }
    var positionUploader: PositionUploader { services!.positionUploader }
    var highlightUploader: HighlightUploader { services!.highlightUploader }
    var remoteChangeFetcher: RemoteChangeFetcher { services!.remoteChangeFetcher }
    var changeApplier: ChangeApplier { services!.changeApplier }
    var syncEngine: SyncEngine { services!.syncEngine }
    var backgroundTaskCoordinator: BackgroundTaskCoordinator { services!.backgroundTaskCoordinator }
    var apnsDeviceRegistrar: APNsDeviceRegistrar { services!.apnsDeviceRegistrar }
    var chatRefreshAdapter: AppChatRefreshAdapter { services!.chatRefreshAdapter }
}
