//
//  RishiSidebarLayout.swift
//  rishi
//
//  Phase 12 Plan 12-02 — top-level layout switch (MAC-02).
//
//  On iPad regular width class AND on Mac Catalyst, render a
//  `NavigationSplitView` with the same "Library" + "Chats" entries that
//  the existing TabView exposes. On iPhone (compact width), fall back to
//  the supplied `compactBody` closure — the existing TabView code stays
//  intact for the iPhone path.
//
//  Choice is purely a function of `horizontalSizeClass`. We force the
//  sidebar on Mac Catalyst regardless of size class because Catalyst can
//  report `.compact` in narrow window states and we want the sidebar
//  affordance there too.
//

import SwiftUI

struct RishiSidebarLayout<Library: View, Chats: View, Compact: View>: View {

    @Binding var selection: MacTab
    @ViewBuilder var library: () -> Library
    @ViewBuilder var chats: () -> Chats
    @ViewBuilder var compactBody: () -> Compact

    @Environment(\.horizontalSizeClass) private var horizontal

    /// `true` whenever we should render the NavigationSplitView (sidebar)
    /// instead of the TabView. Centralised so tests can read the policy
    /// from a single property.
    var prefersSidebar: Bool {
        #if targetEnvironment(macCatalyst)
        return true                              // Mac always splits
        #else
        return horizontal == .regular            // iPad regular = split, iPhone compact = tab
        #endif
    }

    var body: some View {
        if prefersSidebar {
            NavigationSplitView {
                List(selection: $selection) {
                    Label("Library", systemImage: "books.vertical")
                        .tag(MacTab.library)
                    Label("Chats", systemImage: "bubble.left.and.bubble.right")
                        .tag(MacTab.chats)
                }
                .navigationTitle("Rishi")
            } detail: {
                switch selection {
                case .library: library()
                case .chats:   chats()
                }
            }
        } else {
            compactBody()
        }
    }
}

private struct RishiSidebarLayoutPreviewHost: View {
    @State private var selection: MacTab = .library

    var body: some View {
        RishiSidebarLayout(
            selection: $selection,
            library: {
                PreviewPlaceholder(
                    title: "Library",
                    subtitle: "Books and reading progress appear here.",
                    variant: "Sidebar detail"
                )
            },
            chats: {
                PreviewPlaceholder(
                    title: "Chats",
                    subtitle: "Conversations with the reading assistant appear here.",
                    variant: "Sidebar detail"
                )
            },
            compactBody: {
                PreviewPlaceholder(
                    title: "Compact Tabs",
                    subtitle: "iPhone compact width renders a TabView.",
                    variant: "Compact"
                )
            }
        )
    }
}

#Preview("Regular") {
    RishiSidebarLayoutPreviewHost()
        .environment(\.horizontalSizeClass, .regular)
}

#Preview("Compact") {
    RishiSidebarLayoutPreviewHost()
        .environment(\.horizontalSizeClass, .compact)
}
