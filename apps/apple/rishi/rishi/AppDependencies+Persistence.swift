import Foundation
import RishiCore
import RishiDB
import RishiLibrary
import RishiReader
import RishiSearch



extension AppDependencies {
    var dbStore: RishiDBStore { services!.dbStore }
    var bookStore: any BookStore { services!.bookStore }
    var positionStore: any PositionStore { services!.positionStore }
    var highlightStore: any HighlightStore { services!.highlightStore }
    var bookmarkStore: any BookmarkStore { services!.bookmarkStore }
    var bookFileStorage: BookFileStorage { services!.bookFileStorage }
    var importCoordinator: ImportCoordinator { services!.importCoordinator }
    var sampleBookInstaller: SampleBookInstaller { services!.sampleBookInstaller }
    var sampleReaderInstaller: SampleReaderInstaller { services!.sampleReaderInstaller }
    var readerSettingsStore: any ReaderSettingsStore { services!.readerSettingsStore }
}
