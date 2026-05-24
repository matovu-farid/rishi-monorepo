import { useCallback, useEffect, useRef, useState } from 'react'
import {
  View,
  Text,
  FlatList,
  TouchableOpacity,
  KeyboardAvoidingView,
  Platform,
} from 'react-native'
import { SafeAreaView } from 'react-native-safe-area-context'
import { useLocalSearchParams, useRouter } from 'expo-router'
import Animated, { FadeIn, FadeOut } from 'react-native-reanimated'

import { getBookById, getBookForReading } from '@/lib/book-storage'
import {
  createConversation,
  getConversationsForBook,
  addMessage,
  getMessages,
} from '@/lib/conversation-storage'
import { isBookEmbedded } from '@/lib/rag/vector-store'
import { embedBook } from '@/lib/rag/pipeline'
import { useEmbeddingModel } from '@/hooks/useEmbeddingModel'
import { useRAGQuery } from '@/hooks/useRAGQuery'
import { useVoiceInput } from '@/hooks/useVoiceInput'
import { ChatMessage } from '@/components/ChatMessage'
import { ChatInput } from '@/components/ChatInput'
import { ModelDownloadCard } from '@/components/ModelDownloadCard'
import { EmbeddingProgress } from '@/components/EmbeddingProgress'
import { IconSymbol } from '@/components/ui/icon-symbol'
import { useRequireAuth } from '@/components/auth/useRequireAuth'
import { useAuthStore } from '@/lib/stores/authStore'
import {
  resolveReaderPathnameForBook,
  resolveSourceLocationParams,
} from '@/lib/chat/source-location'
import { safeBack } from '@/lib/navigation'
import type { Message, SourceChunk } from '@/types/conversation'
import type { Book } from '@/types/book'

export default function BookChatScreen() {
  // `cid` selects an explicit conversation when navigating from the
  // conversations tab — required because a book can have multiple
  // conversations (P0-N). When absent we fall back to the most recent
  // existing conversation, or create a new one if none exist.
  // `from` provides the previous-screen label shown next to the back
  // chevron (P1-C) — e.g. "Library" or "Conversations" — matching the
  // Apple Books pattern. Optional: when absent the chevron renders bare.
  const { bookId, cid, from } = useLocalSearchParams<{
    bookId: string
    cid?: string
    from?: string
  }>()
  const router = useRouter()
  const flatListRef = useRef<FlatList>(null)

  // Book data
  const [book, setBook] = useState<Book | null>(null)
  // DAT-018 (#130): tri-state load status for the book row. We can't
  // use `book === null` as the "deleted" signal because that's also the
  // initial pre-load state — they look identical until the async
  // `getBookForReading` resolves. `bookStatus` distinguishes:
  //   - 'loading' — initial state, waiting on the async DB read.
  //   - 'present' — found a row.
  //   - 'missing' — DB returned null (deleted / never existed).
  // The embedBook effect and the render branch both gate on this.
  const [bookStatus, setBookStatus] = useState<'loading' | 'present' | 'missing'>(
    'loading',
  )

  // Embedding model
  const { isReady: modelReady, downloadProgress } = useEmbeddingModel()

  // Conversation state
  const [conversationId, setConversationId] = useState<string | null>(null)
  const [messageList, setMessageList] = useState<Message[]>([])

  // Embedding progress
  const [isEmbedding, setIsEmbedding] = useState(false)
  const [embeddingProgress, setEmbeddingProgress] = useState(0)
  const [embeddingTotal, setEmbeddingTotal] = useState(0)
  const [embeddingProcessed, setEmbeddingProcessed] = useState(0)

  // Error state
  const [inlineError, setInlineError] = useState<string | null>(null)
  const [retryQuestion, setRetryQuestion] = useState<string | null>(null)

  // STA-018 (#94): per-message failure status. When a send rejects, the
  // user-message row that triggered it lands in this set. The renderer
  // decorates the row with a tappable "Failed — Tap to retry" badge and
  // a red outline so the user can recover without scrolling up to a
  // global banner. Successful retries clear the entry.
  // We track this in component state rather than the DB row because the
  // status is an in-flight UI concept — the persisted message is still
  // a valid record of "what the user typed".
  const [failedMessageIds, setFailedMessageIds] = useState<Set<string>>(
    () => new Set<string>(),
  )

  // P1-AA: embedding error state. When non-null, an inline banner renders
  // above ChatInput offering Retry. While set, the chat input stays
  // disabled so the user can't send a question against an unprepared book.
  const [embedError, setEmbedError] = useState<string | null>(null)
  // Counter that the retry handler bumps to re-run the embedBook effect.
  const [embedAttempt, setEmbedAttempt] = useState(0)

  // RAG query
  const { askQuestion, isLoading: isQuerying } = useRAGQuery(bookId!)

  // Voice input
  const voice = useVoiceInput()

  const [voiceText, setVoiceText] = useState<string | null>(null)

  // Premium gates — mic + send both require sign-in. The gate hook also
  // owns the "preserve text behind the sheet" behaviour now: it stashes
  // the action's closure (which captures the typed text) and replays it
  // on successful sign-in (P0-U). ChatInput therefore doesn't need any
  // gating-aware prop.
  const requireVoiceInput = useRequireAuth('voice-input')
  const requireAIChat = useRequireAuth('ai-chat')

  // P1-AL: signed-out users must NOT trigger the embed pipeline (which
  // hits the server fallback and fails opaquely). We read auth state
  // here so the embedBook effect can early-return and the screen can
  // render an inline sign-in banner instead.
  const isAuthenticated = useAuthStore((s) => s.isAuthenticated)

  const handleMicPress = useCallback(() => {
    if (voice.isRecording) {
      void voice.stopAndTranscribe().then((transcript) => {
        if (transcript) setVoiceText(transcript)
      })
    } else {
      requireVoiceInput(() => {
        setVoiceText(null)
        void voice.startRecording()
      })
    }
  }, [voice, requireVoiceInput])

  // Load book (async -- triggers R2 download for synced books).
  //
  // DAT-018 (#130): if the row is missing the book was deleted (or never
  // existed). Set `bookStatus = 'missing'` so the render branch shows a
  // "Book was deleted" screen and the embed effect short-circuits.
  useEffect(() => {
    if (!bookId) return
    let cancelled = false
    getBookForReading(bookId)
      .then((result) => {
        if (cancelled) return
        if (result) {
          setBook(result)
          setBookStatus('present')
        } else {
          setBook(null)
          setBookStatus('missing')
        }
      })
      .catch((err) => {
        console.error('Failed to load book for chat:', err)
        if (cancelled) return
        // Surface a missing-book screen on hard-failure too — the user
        // can navigate away rather than stare at an empty chat.
        setBook(null)
        setBookStatus('missing')
      })
    return () => {
      cancelled = true
    }
  }, [bookId])

  // Load or create conversation.
  //
  // Priority:
  //   1. `cid` query param — pick that exact conversation (P0-N).
  //   2. No cid + at least one existing conversation — pick most recent.
  //   3. No cid + no existing conversations — create a fresh one.
  useEffect(() => {
    if (!bookId) return

    const existing = getConversationsForBook(bookId)
    const match = cid ? existing.find((c) => c.id === cid) : undefined
    const target = match ?? existing[0]

    if (target) {
      setConversationId(target.id)
      setMessageList(getMessages(target.id))
    } else {
      const conv = createConversation(bookId)
      setConversationId(conv.id)
      setMessageList([])
    }
  }, [bookId, cid])

  // Start embedding if needed (pipeline handles server fallback internally)
  //
  // P1-AA: surface rejections via `embedError` so the user gets a banner
  // with a Retry control. The retry handler bumps `embedAttempt`, which
  // re-runs this effect. We clear `embedError` at the start of each
  // attempt so a successful retry hides the banner without an extra
  // round-trip.
  useEffect(() => {
    if (!bookId || !book || !book.filePath) return
    if (isBookEmbedded(bookId)) return
    // P1-AL: gate behind authentication. Signed-out users see the
    // sign-in banner below and can opt in via the ai-chat premium gate.
    if (!isAuthenticated) return
    // DAT-018 (#130): re-verify the book row right before firing — the
    // async load races against library bulk-delete. `getBookById` is
    // synchronous against the local DB so it's cheap to call here.
    if (getBookById(bookId) == null) {
      setBookStatus('missing')
      return
    }

    setIsEmbedding(true)
    setEmbeddingTotal(100)
    setEmbeddingProcessed(0)
    setEmbedError(null)

    embedBook(bookId, book.filePath, book.format, (progress) => {
      setEmbeddingProgress(progress)
      setEmbeddingProcessed(Math.round(progress * 100))
      if (progress >= 1) {
        setIsEmbedding(false)
      }
    }).catch((err) => {
      console.error('Embedding failed:', err)
      setIsEmbedding(false)
      setEmbedError('Could not prepare this book for chat.')
    })
  }, [bookId, book, embedAttempt, isAuthenticated])

  const handleEmbedRetry = useCallback(() => {
    setEmbedError(null)
    setEmbedAttempt((n) => n + 1)
  }, [])

  // CHT-006 (#56) / A11Y-006 (#103): an AbortController bound to the
  // currently in-flight `askQuestion`. ChatInput's stop icon invokes
  // `handleAbort`, which calls `.abort()` on this controller; the
  // underlying fetch in `useRAGQuery` rejects with AbortError and the
  // hook flips `isLoading` back to false via its catch+finally.
  const abortRef = useRef<AbortController | null>(null)

  // Drive a RAG turn for an already-persisted user message. Extracted so
  // both the initial send and the per-row retry (STA-018 / #94) share the
  // exact same code path — only the source of the user-message row
  // differs.
  const runTurnForUserMessage = useCallback(
    async (userMsg: Message, currentList: Message[]) => {
      if (!conversationId) return

      const history = [...currentList, userMsg].map((m) => ({
        role: m.role,
        content: m.content,
      }))

      // Fresh controller for THIS turn — abort any prior in-flight
      // controller before swapping so a quick second send doesn't leave
      // a dangling abort handle.
      abortRef.current?.abort()
      const controller = new AbortController()
      abortRef.current = controller

      try {
        const { answer, sources } = await askQuestion(
          userMsg.content,
          history,
          controller.signal,
        )
        const assistantMsg = addMessage(
          conversationId,
          'assistant',
          answer,
          sources,
        )
        setMessageList((prev) => [...prev, assistantMsg])
        // STA-018 (#94): clear the failed-status if this was a retry.
        setFailedMessageIds((prev) => {
          if (!prev.has(userMsg.id)) return prev
          const next = new Set(prev)
          next.delete(userMsg.id)
          return next
        })
      } catch (err) {
        const isAbort =
          (err instanceof Error && err.name === 'AbortError') ||
          controller.signal.aborted
        if (!isAbort) {
          // STA-018 (#94): mark the offending user message so the row
          // itself shows a failed indicator. The global banner stays
          // (for users who don't notice the per-row affordance) but the
          // row is now the primary recovery surface.
          setFailedMessageIds((prev) => {
            if (prev.has(userMsg.id)) return prev
            const next = new Set(prev)
            next.add(userMsg.id)
            return next
          })
          setInlineError(
            'Could not get a response. Check your connection and try again.',
          )
          setRetryQuestion(userMsg.content)
        }
      } finally {
        if (abortRef.current === controller) {
          abortRef.current = null
        }
      }
    },
    [conversationId, askQuestion],
  )

  // Send a message
  const handleSend = useCallback(
    async (text: string) => {
      if (!conversationId || !bookId) return

      setInlineError(null)
      setRetryQuestion(null)

      // Add user message
      const userMsg = addMessage(conversationId, 'user', text)
      setMessageList((prev) => [...prev, userMsg])

      // Build conversation history for RAG. P0-P: include the
      // just-typed user turn — the previous `messageList.map(...)`
      // read the stale closure snapshot, so the LLM was one message
      // behind. Always synthesise the full transcript at call time.
      await runTurnForUserMessage(userMsg, messageList)
    },
    [conversationId, bookId, messageList, runTurnForUserMessage]
  )

  // STA-018 (#94): per-row retry. Re-runs the RAG turn for a previously
  // failed user message without re-adding it to the conversation.
  const handleRetryFailedMessage = useCallback(
    (userMsg: Message) => {
      // Hide any global banner — the per-row UI is the source of truth
      // now.
      setInlineError(null)
      setRetryQuestion(null)
      // History is everything BEFORE the failed turn (the failed user
      // message is appended inside runTurnForUserMessage's history call).
      const indexInList = messageList.findIndex((m) => m.id === userMsg.id)
      const historyBefore =
        indexInList >= 0 ? messageList.slice(0, indexInList) : messageList
      void runTurnForUserMessage(userMsg, historyBefore)
    },
    [messageList, runTurnForUserMessage],
  )

  const handleAbort = useCallback(() => {
    abortRef.current?.abort()
  }, [])

  const handleRetry = useCallback(() => {
    if (retryQuestion) {
      handleSend(retryQuestion)
    }
  }, [retryQuestion, handleSend])

  const handleSourcePress = useCallback(
    (source: SourceChunk) => {
      // P1-A: route to the format-appropriate reader screen. The
      // previous unconditional `/reader/${bookId}` opened the EPUB
      // reader for every format and errored out on PDF / MOBI / DJVU.
      //
      // #68: thread the chunk's location into the router push so the
      // reader can scroll to the cited passage on mount. Pre-fix the
      // chip discarded `source.chunkId` / `source.chapter`, so the
      // citation was non-actionable. `resolveSourceLocationParams`
      // parses the chunker's per-format chapter labels back into the
      // query params each reader honors (`?page=` for PDF/DJVU,
      // `?chapter=` for MOBI/AZW3, `?cfi=` for EPUB when available).
      if (!book) return
      router.push({
        pathname: resolveReaderPathnameForBook(book.format),
        params: resolveSourceLocationParams(book, source),
      })
    },
    [book, router]
  )

  // Show model download card if not ready
  const showModelDownload = !modelReady && downloadProgress < 1
  const isModelDownloading = !modelReady && downloadProgress > 0

  // Determine if chat input should be disabled.
  // P1-AA: while an embed error is showing, the book isn't prepared —
  // keep send locked until the user retries successfully (or navigates
  // away).
  // P1-AL: signed-out users also can't send — the embed pipeline never
  // ran. Keep send locked until they sign in via the inline CTA.
  const chatDisabled =
    !isAuthenticated ||
    isEmbedding ||
    embedError !== null ||
    !isBookEmbedded(bookId!)

  // Inverted data for FlatList
  const invertedMessages = [...messageList].reverse()

  // Per-role 0-based indices keyed by message id. The FlatList renders
  // messages in reverse, but the indices we expose via testID are
  // computed against the chronological order (oldest user message is
  // `chat-message-user-0`, oldest assistant message is
  // `chat-message-assistant-0`, etc.). This is what the E2E tests
  // assert against.
  const messageIndexById = new Map<string, number>()
  {
    let userIdx = 0
    let assistantIdx = 0
    for (const m of messageList) {
      messageIndexById.set(m.id, m.role === 'user' ? userIdx++ : assistantIdx++)
    }
  }

  // DAT-018 (#130): book row vanished — render a dedicated error screen
  // so the user knows the book is gone and can navigate away. We render
  // BEFORE the main content branch so none of the embedding /
  // conversation effects produce visible UI.
  if (bookStatus === 'missing') {
    return (
      <SafeAreaView
        testID="screen-chat-detail"
        className="flex-1 bg-white dark:bg-[#151718]"
        edges={['top']}
      >
        <View className="flex-row items-center justify-between h-12 px-4 border-b border-gray-200 dark:border-gray-700">
          <TouchableOpacity
            onPress={() => safeBack(router)}
            className="flex-row items-center h-11 pl-1 pr-2"
            accessibilityLabel={from ? `Back to ${from}` : 'Back'}
            accessibilityRole="button"
          >
            <IconSymbol name="chevron.left" size={22} color="#0a7ea4" />
            {from ? (
              <Text
                testID="chat-detail-back-label"
                className="text-base text-[#0a7ea4] ml-0.5"
                numberOfLines={1}
              >
                {from}
              </Text>
            ) : null}
          </TouchableOpacity>
          <Text className="flex-1 text-base font-semibold text-gray-900 dark:text-white text-center mx-2">
            Chat
          </Text>
          <View className="w-11 h-11" />
        </View>
        <View
          testID="chat-deleted-book-error"
          className="flex-1 items-center justify-center p-8"
        >
          <IconSymbol name="exclamationmark.triangle" size={40} color="#9CA3AF" />
          <Text className="text-base font-semibold text-gray-900 dark:text-white mt-4 text-center">
            Book was deleted
          </Text>
          <Text className="text-sm text-gray-500 dark:text-gray-400 mt-1 text-center">
            This book is no longer in your library. Start a new chat from another
            book to continue.
          </Text>
          <TouchableOpacity
            testID="chat-deleted-book-back"
            onPress={() => safeBack(router)}
            className="mt-6 px-4 py-2 rounded-md bg-[#0a7ea4]"
            accessibilityRole="button"
            accessibilityLabel="Go back"
          >
            <Text className="text-white font-semibold">Go back</Text>
          </TouchableOpacity>
        </View>
      </SafeAreaView>
    )
  }

  return (
    <SafeAreaView testID="screen-chat-detail" className="flex-1 bg-white dark:bg-[#151718]" edges={['top']}>
      <KeyboardAvoidingView
        className="flex-1"
        behavior={Platform.OS === 'ios' ? 'padding' : 'height'}
        keyboardVerticalOffset={0}
      >
        {/* Header */}
        <View className="flex-row items-center justify-between h-12 px-4 border-b border-gray-200 dark:border-gray-700">
          <TouchableOpacity
            // P1-B: safeBack guards deep-link cold-start where the nav
            // stack is empty (e.g. opened from a notification or fresh
            // launch into /chat/<bookId>) — replaces to /(tabs) instead
            // of no-op'ing.
            onPress={() => safeBack(router)}
            className="flex-row items-center h-11 pl-1 pr-2"
            accessibilityLabel={from ? `Back to ${from}` : 'Back'}
            accessibilityRole="button"
          >
            <IconSymbol name="chevron.left" size={22} color="#0a7ea4" />
            {from ? (
              <Text
                testID="chat-detail-back-label"
                className="text-base text-[#0a7ea4] ml-0.5"
                numberOfLines={1}
              >
                {from}
              </Text>
            ) : null}
          </TouchableOpacity>

          <Text
            className="flex-1 text-base font-semibold text-gray-900 dark:text-white text-center mx-2"
            numberOfLines={1}
          >
            {book?.title ?? 'Chat'}
          </Text>

          <View className="w-11 h-11" />
        </View>

        {/* Content area */}
            <FlatList
              ref={flatListRef}
              data={invertedMessages}
              keyExtractor={(item) => item.id}
              inverted
              renderItem={({ item }) => {
                const failed =
                  item.role === 'user' && failedMessageIds.has(item.id)
                return (
                  <View testID={failed ? `chat-message-failed-${item.id}` : undefined}>
                    <ChatMessage
                      message={item}
                      onSourcePress={handleSourcePress}
                      testID={`chat-message-${item.role}-${messageIndexById.get(item.id) ?? 0}`}
                    />
                    {failed && (
                      // STA-018 (#94): per-row failure badge. Red outline +
                      // tappable "Failed — Tap to retry" affordance lives
                      // outside ChatMessage to keep that component's
                      // contract narrow (it owns bubble rendering only).
                      <View className="items-end px-4 pb-1">
                        <TouchableOpacity
                          testID={`chat-message-failed-retry-${item.id}`}
                          onPress={() => handleRetryFailedMessage(item)}
                          accessibilityRole="button"
                          accessibilityLabel="Retry sending this message"
                          className="flex-row items-center gap-1 px-2 py-1 rounded-md border border-red-400"
                        >
                          <IconSymbol
                            name="exclamationmark.triangle"
                            size={12}
                            color="#dc2626"
                          />
                          <Text className="text-xs text-red-600 font-medium">
                            Failed — Tap to retry
                          </Text>
                        </TouchableOpacity>
                      </View>
                    )}
                  </View>
                )
              }}
              contentContainerStyle={{ paddingVertical: 8 }}
              ListFooterComponent={
                <>
                  {isEmbedding && book && (
                    <Animated.View entering={FadeIn.duration(200)} exiting={FadeOut.duration(200)}>
                      <EmbeddingProgress
                        bookTitle={book.title}
                        progress={embeddingProgress}
                        totalChunks={embeddingTotal}
                        processedChunks={embeddingProcessed}
                      />
                    </Animated.View>
                  )}
                  {showModelDownload && (
                    <View className="px-4 py-2">
                      <ModelDownloadCard
                        downloadProgress={downloadProgress}
                        isDownloading={isModelDownloading}
                        onDownload={() => {}}
                      />
                    </View>
                  )}
                </>
              }
              ListHeaderComponent={
                <>
                  {/* Typing indicator */}
                  {isQuerying && (
                    <TypingIndicator />
                  )}

                  {/* Inline error */}
                  {inlineError && (
                    <View className="px-4 py-2 items-start">
                      <View className="max-w-[80%] bg-gray-100 dark:bg-[#2A2D2F] rounded-2xl rounded-bl-sm px-4 py-2">
                        <Text className="text-base text-red-600">
                          {inlineError}
                        </Text>
                        <TouchableOpacity onPress={handleRetry} className="mt-1">
                          <Text className="text-sm text-[#0a7ea4] font-semibold">
                            Try again
                          </Text>
                        </TouchableOpacity>
                      </View>
                    </View>
                  )}
                </>
              }
              ListEmptyComponent={
                !isEmbedding ? (
                  <View className="flex-1 items-center justify-center p-8" style={{ transform: [{ scaleY: -1 }] }}>
                    <IconSymbol name="sparkles" size={40} color="#9CA3AF" />
                    <Text className="text-base font-semibold text-gray-900 dark:text-white mt-4">
                      Ask anything about this book
                    </Text>
                    <Text className="text-sm text-gray-500 dark:text-gray-400 mt-1 text-center">
                      Ask questions about characters, themes, or anything you want to understand better.
                    </Text>
                  </View>
                ) : null
              }
            />

            {/* P1-AL: signed-out gate. We never fired embedBook, so the
                book isn't prepared; surface that explicitly with a
                sign-in CTA that funnels through the ai-chat premium
                gate (which knows how to replay the action on success). */}
            {!isAuthenticated && (
              <View
                testID="chat-signin-gate-banner"
                className="mx-4 mb-2 px-4 py-3 rounded-lg bg-blue-50 dark:bg-blue-950 border border-blue-200 dark:border-blue-900 flex-row items-center justify-between"
              >
                <Text className="flex-1 text-sm text-blue-800 dark:text-blue-100 pr-3">
                  Sign in to prepare this book for chat.
                </Text>
                <TouchableOpacity
                  testID="chat-signin-gate-cta"
                  onPress={() => requireAIChat(() => {})}
                  accessibilityRole="button"
                  accessibilityLabel="Sign in to chat with this book"
                  className="px-3 py-1.5 rounded-md bg-[#0a7ea4]"
                >
                  <Text className="text-sm font-semibold text-white">Sign in</Text>
                </TouchableOpacity>
              </View>
            )}

            {/* P1-AA: embedding-failure banner with Retry. Rendered above
                ChatInput so the input remains visible but disabled. */}
            {embedError && (
              <View
                testID="chat-embed-error-banner"
                className="mx-4 mb-2 px-4 py-3 rounded-lg bg-red-50 dark:bg-red-950 border border-red-200 dark:border-red-900 flex-row items-center justify-between"
              >
                <Text className="flex-1 text-sm text-red-700 dark:text-red-200 pr-3">
                  Could not prepare this book — {embedError}
                </Text>
                <TouchableOpacity
                  testID="chat-embed-error-retry"
                  onPress={handleEmbedRetry}
                  accessibilityRole="button"
                  accessibilityLabel="Retry preparing this book"
                  className="px-3 py-1.5 rounded-md bg-red-600"
                >
                  <Text className="text-sm font-semibold text-white">Retry</Text>
                </TouchableOpacity>
              </View>
            )}

            <ChatInput
              onSend={(text) => requireAIChat(() => void handleSend(text))}
              isLoading={isQuerying}
              disabled={chatDisabled}
              onMicPress={handleMicPress}
              isRecording={voice.isRecording}
              isTranscribing={voice.isTranscribing}
              voiceError={voice.error}
              permissionDenied={voice.permissionDenied}
              externalText={voiceText}
              // CHT-006 (#56) / A11Y-006 (#103): wire abort. ChatInput's
              // send button morphs into a stop-fill icon while
              // `isLoading` is true; tapping it now calls into our
              // AbortController and cancels the in-flight LLM fetch.
              onAbort={handleAbort}
            />
      </KeyboardAvoidingView>
    </SafeAreaView>
  )
}

/** Three-dot typing indicator in an assistant bubble */
function TypingIndicator() {
  return (
    <Animated.View
      entering={FadeIn.duration(150)}
      className="px-4 py-2 items-start"
    >
      <View className="bg-gray-100 dark:bg-[#2A2D2F] rounded-2xl rounded-bl-sm px-4 py-3 flex-row"
        accessibilityLabel="AI is thinking"
      >
        <PulsingDot delay={0} />
        <PulsingDot delay={200} />
        <PulsingDot delay={400} />
      </View>
    </Animated.View>
  )
}

function PulsingDot({ delay }: { delay: number }) {
  const [opacity, setOpacity] = useState(0.3)

  useEffect(() => {
    let mounted = true
    const cycle = () => {
      if (!mounted) return
      setOpacity(1)
      setTimeout(() => {
        if (!mounted) return
        setOpacity(0.3)
      }, 300)
    }

    const timeout = setTimeout(() => {
      cycle()
      const interval = setInterval(cycle, 600)
      return () => clearInterval(interval)
    }, delay)

    return () => {
      mounted = false
      clearTimeout(timeout)
    }
  }, [delay])

  return (
    <View
      className="w-2 h-2 rounded-full bg-gray-400 mx-0.5"
      style={{ opacity }}
    />
  )
}
