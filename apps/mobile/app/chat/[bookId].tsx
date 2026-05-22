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
import type { Message, SourceChunk } from '@/types/conversation'
import type { Book } from '@/types/book'

export default function BookChatScreen() {
  // `cid` selects an explicit conversation when navigating from the
  // conversations tab — required because a book can have multiple
  // conversations (P0-N). When absent we fall back to the most recent
  // existing conversation, or create a new one if none exist.
  const { bookId, cid } = useLocalSearchParams<{ bookId: string; cid?: string }>()
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
  useEffect(() => {
    if (!bookId || !book || !book.filePath) return
    if (isBookEmbedded(bookId)) return

    setIsEmbedding(true)
    setEmbeddingTotal(100)
    setEmbeddingProcessed(0)

    embedBook(bookId, book.filePath, book.format, (progress) => {
      setEmbeddingProgress(progress)
      setEmbeddingProcessed(Math.round(progress * 100))
      if (progress >= 1) {
        setIsEmbedding(false)
      }
    }).catch((err) => {
      console.error('Embedding failed:', err)
      setIsEmbedding(false)
    })
  }, [bookId, book])

  // Send a message
  const handleSend = useCallback(
    async (text: string) => {
      if (!conversationId || !bookId) return

      setInlineError(null)
      setRetryQuestion(null)

      // Add user message
      const userMsg = addMessage(conversationId, 'user', text)
      setMessageList((prev) => [...prev, userMsg])

      // Build conversation history for RAG
      const history = messageList.map((m) => ({
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
      if (bookId) {
        router.push(`/reader/${bookId}`)
      }
    },
    [bookId, router]
  )

  // Show model download card if not ready
  const showModelDownload = !modelReady && downloadProgress < 1
  const isModelDownloading = !modelReady && downloadProgress > 0

  // Determine if chat input should be disabled
  const chatDisabled = isEmbedding || !isBookEmbedded(bookId!)

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
            onPress={() => router.back()}
            className="w-11 h-11 items-center justify-center"
            accessibilityLabel="Back"
            accessibilityRole="button"
          >
            <IconSymbol name="chevron.left" size={22} color="#687076" />
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
