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
//  Choice is purely a function of `horizontalSizeClass`. The
//  `.navigationSplitViewStyle(.balanced)` modifier hands sidebar
//  pinning vs. auto-collapse to the system: wide Catalyst / iPad
//  windows pin the sidebar inline; narrow windows collapse it to a
//  toggle button at the top-left, matching macOS Finder / Mail.
//
//  Phase 18 Plan 18-04 (F-P1-04) — replaced the previous
//  Catalyst-always-pin compile-time gate with the native
//  auto-collapse policy driven by the size class + split-view style.
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
    ///
    /// On iPhone-class widths (compact horizontal) the TabView wins.
    /// On iPad and Mac Catalyst the NavigationSplitView is used and the
    /// `.balanced` style decides whether to pin the sidebar inline or
    /// collapse it to a toggle button based on the current window width.
    var prefersSidebar: Bool {
        horizontal == .regular
    }

    private var selectionOptional: Binding<MacTab?> {
        Binding(
            get: { selection },
            set: { if let new = $0 { selection = new } }
        )
    }

    var body: some View {
        if prefersSidebar {
            NavigationSplitView {
                List(selection: selectionOptional) {
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
            .navigationSplitViewStyle(.balanced)
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
