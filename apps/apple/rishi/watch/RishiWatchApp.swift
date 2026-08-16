#if os(watchOS)

import SwiftUI

@main
struct RishiWatchApp: App {
    private let model = RishiWatchViewModel(client: RishiWatchConnectivityClient())

    var body: some Scene {
        WindowGroup { RishiWatchView(model: model) }
    }
}

#endif
