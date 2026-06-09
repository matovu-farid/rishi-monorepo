// ReaderHost.swift
// Spike A — SwiftUI host for an EPUBNavigatorViewController.
//
// Validates on Mac Catalyst:
//   (a) Publication opens; first page renders text.
//   (b) Forward/back paging advances chapters and emits a CFI-shaped locator.
//   (c) TOC list shows chapter entries that navigate when tapped.
//   (d) Decorations API call returns without exception and draws a highlight.
//   (e) Trackpad two-finger swipe and arrow-key paging work.
//
// All navigator delegate callbacks are printed with the "[SpikeA]" tag for
// log-grep verification.

import SwiftUI
import UIKit
import ReadiumShared
import ReadiumStreamer
import ReadiumNavigator

// MARK: - Reader host view

struct ReaderHost: View {
    @State private var coordinator = ReaderCoordinator()
    @State private var showTOC = false
    @State private var status: String = "Initializing…"

    var body: some View {
        VStack(spacing: 0) {
            // Reader surface
            if let navigator = coordinator.navigator {
                EPUBNavigatorRepresentable(navigator: navigator)
                    .ignoresSafeArea(edges: [.horizontal, .bottom])
            } else {
                ZStack {
                    Color(white: 0.96)
                    VStack(spacing: 12) {
                        ProgressView()
                        Text(status)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            // Toolbar
            HStack(spacing: 12) {
                Button("Previous page") {
                    Task { await coordinator.goBackward() }
                }
                .disabled(coordinator.navigator == nil)

                Button("Next page") {
                    Task { await coordinator.goForward() }
                }
                .disabled(coordinator.navigator == nil)

                Button("Show TOC") { showTOC = true }
                    .disabled(coordinator.publication == nil)

                Button("Highlight selection") {
                    Task { await coordinator.highlightCurrentSelection() }
                }
                .disabled(coordinator.navigator == nil)

                Spacer()
                Text(coordinator.lastLocatorDescription)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .padding()
            .background(.thinMaterial)
        }
        .task {
            do {
                try await coordinator.load()
                status = "Loaded"
            } catch {
                status = "Failed to load: \(error.localizedDescription)"
                print("[SpikeA] load failed: \(error)")
            }
        }
        .sheet(isPresented: $showTOC) {
            TOCView(
                entries: coordinator.tocEntries,
                onSelect: { link in
                    showTOC = false
                    Task { await coordinator.go(to: link) }
                }
            )
        }
    }
}

// MARK: - UIViewControllerRepresentable wrapper

private struct EPUBNavigatorRepresentable: UIViewControllerRepresentable {
    let navigator: EPUBNavigatorViewController

    func makeUIViewController(context: Context) -> EPUBNavigatorViewController {
        navigator
    }

    func updateUIViewController(_ uiViewController: EPUBNavigatorViewController, context: Context) {
        // navigator is owned by the coordinator; no per-update mutation here.
    }
}

// MARK: - TOC view

private struct TOCView: View {
    let entries: [ReadiumShared.Link]
    let onSelect: (ReadiumShared.Link) -> Void

    var body: some View {
        NavigationStack {
            List(entries, id: \.href) { link in
                Button {
                    onSelect(link)
                } label: {
                    VStack(alignment: .leading) {
                        Text(link.title ?? link.href)
                            .font(.body)
                        Text(link.href)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("Table of Contents")
        }
    }
}

// MARK: - Coordinator

@MainActor
@Observable
final class ReaderCoordinator: NSObject {
    private(set) var publication: Publication?
    private(set) var navigator: EPUBNavigatorViewController?
    private(set) var lastLocator: Locator?
    private(set) var tocEntries: [ReadiumShared.Link] = []

    var lastLocatorDescription: String {
        guard let l = lastLocator else { return "no position yet" }
        // CFI lives in locations.otherLocations["cfi"] when Readium produces one.
        // JSONValue → String extraction for the display label.
        let cfi: String = {
            guard let raw = l.locations.otherLocations["cfi"] else { return "—" }
            if case let .string(s) = raw { return s }
            return String(describing: raw)
        }()
        let progression = l.locations.progression.map { String(format: "%.2f", $0) } ?? "—"
        return "href=\(l.href) progression=\(progression) cfi=\(cfi)"
    }

    func load() async throws {
        guard let url = Bundle.module.url(forResource: "sample", withExtension: "epub") else {
            throw NSError(domain: "SpikeA", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "sample.epub not found in bundle resources",
            ])
        }
        print("[SpikeA] loading sample.epub from \(url.path)")

        // Open the asset via the AssetRetriever + Streamer pipeline (Readium 3.x API).
        let httpClient = DefaultHTTPClient()
        let assetRetriever = AssetRetriever(httpClient: httpClient)
        guard let fileURL = FileURL(url: url) else {
            throw NSError(domain: "SpikeA", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "Unable to convert sample.epub URL to FileURL",
            ])
        }
        let asset = try await assetRetriever.retrieve(url: fileURL).get()
        let publicationOpener = PublicationOpener(
            parser: DefaultPublicationParser(
                httpClient: httpClient,
                assetRetriever: assetRetriever,
                pdfFactory: DefaultPDFDocumentFactory()
            )
        )
        let publication = try await publicationOpener.open(asset: asset, allowUserInteraction: false).get()
        self.publication = publication
        // Hydrate the TOC for the sheet UI.
        // Manifest.tableOfContents is a synchronous `[Link]` — preferred over
        // the async service-based accessor for spike simplicity.
        self.tocEntries = publication.manifest.tableOfContents

        // Construct the navigator using the modern (no-httpServer) init.
        let navigator = try EPUBNavigatorViewController(
            publication: publication,
            initialLocation: nil
        )
        navigator.delegate = self
        self.navigator = navigator
        let title = publication.metadata.title ?? "<no title>"
        print("[SpikeA] navigator constructed; title=\(title)")
    }

    func goForward() async {
        guard let navigator else { return }
        let ok = await navigator.goForward(options: NavigatorGoOptions(animated: true))
        print("[SpikeA] goForward → \(ok)")
    }

    func goBackward() async {
        guard let navigator else { return }
        let ok = await navigator.goBackward(options: NavigatorGoOptions(animated: true))
        print("[SpikeA] goBackward → \(ok)")
    }

    func go(to link: ReadiumShared.Link) async {
        guard let navigator else { return }
        let ok = await navigator.go(to: link, options: NavigatorGoOptions(animated: true))
        print("[SpikeA] go(toLink:\(link.href)) → \(ok)")
    }

    func highlightCurrentSelection() async {
        guard let navigator else { return }
        guard let selection = navigator.currentSelection else {
            print("[SpikeA] highlight: no current selection")
            return
        }
        let decoration = Decoration(
            id: "spike-a-highlight-\(UUID().uuidString)",
            locator: selection.locator,
            style: .highlight(tint: .yellow, isActive: true)
        )
        // Decorations API is fire-and-forget (not async / not throwing).
        navigator.apply(decorations: [decoration], in: "spike-a-highlights")
        print("[SpikeA] highlight applied at \(selection.locator.href)")
    }
}

// MARK: - EPUBNavigatorDelegate (all @MainActor by protocol declaration)

extension ReaderCoordinator: EPUBNavigatorDelegate {
    func navigator(_ navigator: any Navigator, locationDidChange locator: Locator) {
        self.lastLocator = locator
        print("[SpikeA] locationDidChange href=\(locator.href) progression=\(locator.locations.progression ?? -1)")
    }

    func navigator(_ navigator: any Navigator, presentExternalURL url: URL) {
        print("[SpikeA] presentExternalURL \(url)")
    }

    func navigator(_ navigator: any Navigator, presentError error: NavigatorError) {
        print("[SpikeA] presentError \(error)")
    }
}
