

import SwiftUI
import RishiReader   
import RishiSync     



func shouldRunAutoSync(_ autoSync: Bool) -> Bool { autoSync }

#if targetEnvironment(macCatalyst)


@MainActor
struct ReaderPrefsMenuModel {
    var theme: Binding<ReaderTheme>
    var pdfViewMode: Binding<PDFViewModeSetting>
    var fontFamily: Binding<ReaderFontFamily>
    var voice: Binding<String>
    var speed: Binding<Double>
    var autoSync: Binding<Bool>
    var onSyncNow: () -> Void
    var syncStatus: SyncStatus
}

private struct ReaderPrefsMenuKey: FocusedValueKey {
    typealias Value = ReaderPrefsMenuModel
}

extension FocusedValues {
    var readerPrefsMenu: ReaderPrefsMenuModel? {
        get { self[ReaderPrefsMenuKey.self] }
        set { self[ReaderPrefsMenuKey.self] = newValue }
    }
}

#endif
