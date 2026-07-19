//
//  SwiftUIView.swift
//  RishiReader
//
//  Created by Farid Matovu on 03/07/2026.
//

import SwiftUI
import Foundation
import RishiCore
import RishiUIKit
import SwiftUI
import os.signpost

public struct ReaderToolBar: ViewModifier {
    private let onReadAloud: (() -> Void)?
    private var chrome: ReaderChromeController
    private let voiceChatTip = VoiceChatTip()
    private let readAloudTip = ReadAloudTip()
    private let voicePresenter: (any ReaderVoicePresenter)?
    private let viewModel: PDFReaderViewModel
    @Binding private var activeSheet: ReaderSheet?
    
    @Binding private var bookmarkToggle: PDFBookmarkToggleModel?
    
    
    public init(onReadAloud: (() -> Void)?, chrome: ReaderChromeController, voicePresenter: (any ReaderVoicePresenter)?, viewModel: PDFReaderViewModel, activeSheet: Binding<ReaderSheet?> , bookmarkToggle: Binding<PDFBookmarkToggleModel?>) {
        self.onReadAloud = onReadAloud
        self.chrome = chrome
        self.voicePresenter = voicePresenter
        self.viewModel = viewModel
        self._activeSheet = activeSheet
        self._bookmarkToggle = bookmarkToggle
    }
    
    public func body(content: Content) -> some View {
        content
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    
                    if let onReadAloud {
                        Button {
                            chrome.userActivity()
                            onReadAloud()
                        } label: {
                            Image(systemName: "speaker.wave.2.fill")
                        }
                        .popoverTip(readAloudTip)
                        .accessibilityIdentifier("reader.toolbar.readAloud")
                        .accessibilityLabel(A11yLabel.readerReadAloud)
                    }
                    
                    if let voicePresenter {
                        Button {
                            chrome.userActivity()
                            voicePresenter.presentVoice(
                                bookId: viewModel.book.id,
                                context: viewModel.voiceContext(),
                                initialQuote: nil
                            )
                        } label: {
                            Image(systemName: "waveform.circle.fill")
                        }
                        .popoverTip(voiceChatTip)
                        .accessibilityIdentifier("reader.toolbar.voice")
                        .accessibilityLabel(A11yLabel.readerOpenVoice)
                    }
                    
                    Button {
                        chrome.userActivity()
                        activeSheet = .theme
                    } label: {
                        Image(systemName: "circle.lefthalf.filled")
                    }
                    .accessibilityIdentifier("reader.toolbar.theme")
                    .accessibilityLabel(A11yLabel.readerOpenTheme)
                    
                    Menu {
                        Button {
                            chrome.userActivity()
                            activeSheet = .toc
                        } label: {
                            Label(
                                "Contents",
                                systemImage: "list.bullet.indent"
                            )
                        }
                        .accessibilityIdentifier("reader.toolbar.toc")
                        
                        Button {
                            chrome.userActivity()
                            Task {
                                await bookmarkToggle?.toggle(
                                    currentPage: viewModel.pageIndex,
                                    snippet: nil
                                )
                            }
                        } label: {
                            Label(
                                (bookmarkToggle?.isBookmarked ?? false)
                                ? "Remove Bookmark" : "Add Bookmark",
                                systemImage: (bookmarkToggle?.isBookmarked
                                              ?? false) ? "bookmark.fill" : "bookmark"
                            )
                        }
                        .accessibilityIdentifier("reader.toolbar.bookmark")
                        
                        Button {
                            chrome.userActivity()
                            Task {
                                await bookmarkToggle?.refresh(
                                    currentPage: viewModel.pageIndex
                                )
                            }
                            activeSheet = .bookmarks
                        } label: {
                            Label(
                                "Bookmarks",
                                systemImage: "bookmark.circle"
                            )
                        }
                        .accessibilityIdentifier(
                            "reader.toolbar.bookmarksList"
                        )
                        
                        Button {
                            chrome.userActivity()
                            activeSheet = .search
                        } label: {
                            Label("Search", systemImage: "magnifyingglass")
                        }
                        .accessibilityIdentifier("reader.toolbar.search")
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .accessibilityIdentifier("reader.toolbar.more")
                    .accessibilityLabel("More")
                }
            }
        
            .toolbar(
                navBarVisibility(forChromeVisible: chrome.isVisible),
                for: .navigationBar
            )
            .toolbar(
                navBarVisibility(forChromeVisible: chrome.isVisible),
                for: .bottomBar
            )
            .onDisappear {
                
                Task { await viewModel.flush() }
            }
        
            .preferredColorScheme(viewModel.theme.preferredColorScheme)
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
    }
}

extension View {
    func readerToolBar(onReadAloud: (() -> Void)?, chrome: ReaderChromeController, voicePresenter: (any ReaderVoicePresenter)?,viewModel: PDFReaderViewModel, activeSheet: Binding<ReaderSheet?>, bookmarkToggle: Binding<PDFBookmarkToggleModel?>) -> some View {
        modifier(ReaderToolBar(
            onReadAloud: onReadAloud,
            chrome: chrome,
            voicePresenter: voicePresenter,
            viewModel: viewModel,
            activeSheet: activeSheet,
            bookmarkToggle: bookmarkToggle
          
        ))
    }
}
// (any ReaderVoicePresenter)?'
