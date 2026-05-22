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

import { getBookForReading } from '@/lib/book-storage'
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
import { resolveReaderRouteForBook } from '@/lib/reader-routes'
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

  // Load book (async -- triggers R2 download for synced books)
  useEffect(() => {
    if (bookId) {
      getBookForReading(bookId).then(setBook).catch(err => {
        console.error('Failed to load book for chat:', err)
      })
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
      const history = [...messageList, userMsg].map((m) => ({
        role: m.role,
        content: m.content,
      }))

      try {
        const { answer, sources } = await askQuestion(text, history)
        const assistantMsg = addMessage(conversationId, 'assistant', answer, sources)
        setMessageList((prev) => [...prev, assistantMsg])
      } catch (_err) {
        setInlineError('Could not get a response. Check your connection and try again.')
        setRetryQuestion(text)
      }
    },
    [conversationId, bookId, messageList, askQuestion]
  )

  const handleRetry = useCallback(() => {
    if (retryQuestion) {
      handleSend(retryQuestion)
    }
  }, [retryQuestion, handleSend])

  const handleSourcePress = useCallback(
    (_source: SourceChunk) => {
      // P1-A: route to the format-appropriate reader screen. The
      // previous unconditional `/reader/${bookId}` opened the EPUB
      // reader for every format and errored out on PDF / MOBI / DJVU.
      if (!book) return
      router.push(resolveReaderRouteForBook(book))
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
              renderItem={({ item }) => (
                <ChatMessage
                  message={item}
                  onSourcePress={handleSourcePress}
                  testID={`chat-message-${item.role}-${messageIndexById.get(item.id) ?? 0}`}
                />
              )}
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
