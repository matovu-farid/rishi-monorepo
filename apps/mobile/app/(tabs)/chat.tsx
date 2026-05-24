import { useCallback, useMemo, useState } from 'react'
import { View, FlatList, TouchableOpacity, Alert, Text } from 'react-native'
import { SafeAreaView } from 'react-native-safe-area-context'
import { useRouter, useFocusEffect } from 'expo-router'
import { IconSymbol } from '@/components/ui/icon-symbol'
import { ConversationRow } from '@/components/ConversationRow'
import { LockChip } from '@/components/auth/LockChip'
import { useRequireAuth } from '@/components/auth/useRequireAuth'
import { useAuthStore } from '@/lib/stores/authStore'
import {
  getAllConversations,
  getMessages,
  softDeleteConversation,
} from '@/lib/conversation-storage'
import { getBookById } from '@/lib/book-storage'
import { getBooks } from '@/lib/book-storage'
import { isBookEmbedded } from '@/lib/rag/vector-store'
import { NewConversationSheet } from '@/components/chat/NewConversationSheet'
import type { Book } from '@/types/book'
import type { Conversation } from '@/types/conversation'

export default function ConversationsScreen() {
  const router = useRouter()
  const [conversations, setConversations] = useState<Conversation[]>([])
  const [isSheetOpen, setSheetOpen] = useState(false)
  const requireAIChat = useRequireAuth('ai-chat')
  // P1-T — render a tiny lock chip overlay on the "New conversation" +
  // button when the user is signed out. The tap itself still fires (it
  // opens the premium gate via requireAIChat); the chip is purely a
  // visual affordance.
  const isAuthenticated = useAuthStore((s) => s.isAuthenticated)

  const loadConversations = useCallback(() => {
    setConversations(getAllConversations())
  }, [])

  // P0-M: filter out conversations whose underlying book has been deleted.
  // Otherwise the row renders "Unknown Book" and tap navigates into a
  // dead chat detail. The cheaper alternative — keeping the row and
  // showing a CTA — was rejected because the book is gone for good.
  const visibleConversations = useMemo(
    () => conversations.filter((c) => getBookById(c.bookId) !== null),
    [conversations],
  )

  useFocusEffect(
    useCallback(() => {
      loadConversations()
    }, [loadConversations])
  )

  // P1-AH — open the NewConversationSheet instead of an Alert button list.
  // Alert capped at 10 buttons on iOS and gave no embed-status signal; the
  // sheet shows every imported book plus a Ready/Preparing badge so the
  // user can tell which titles are already chat-ready.
  const handleNewConversation = useCallback(() => {
    requireAIChat(() => {
      setSheetOpen(true)
    })
  }, [requireAIChat])

  // Snapshotting the library when the sheet opens keeps the FlatList stable
  // for the duration of the interaction (and avoids re-querying SQLite on
  // every render).
  const libraryBooks = useMemo<Book[]>(
    () => (isSheetOpen ? getBooks() : []),
    [isSheetOpen],
  )

  const handleSelectBookFromSheet = useCallback(
    (book: Book) => {
      setSheetOpen(false)
      router.push(`/chat/${book.id}?from=Conversations`)
    },
    [router],
  )

  const handleDelete = useCallback(
    (id: string) => {
      Alert.alert(
        'Delete Conversation',
        'This conversation will be removed from all your devices.',
        [
          { text: 'Cancel', style: 'cancel' },
          {
            text: 'Delete',
            style: 'destructive',
            onPress: () => {
              softDeleteConversation(id)
              loadConversations()
            },
          },
        ]
      )
    },
    [loadConversations]
  )

  const getLastMessage = useCallback((conversationId: string): string | undefined => {
    const msgs = getMessages(conversationId)
    if (msgs.length === 0) return undefined
    const last = msgs[msgs.length - 1]
    return last.content.slice(0, 60)
  }, [])

  if (visibleConversations.length === 0) {
    return (
      <SafeAreaView testID="screen-chat-list" className="flex-1 bg-white dark:bg-[#151718]">
        <View className="px-6 pt-4 pb-2 flex-row items-center justify-between">
          <Text testID="conversations-title" className="text-2xl font-semibold text-gray-900 dark:text-white">
            Conversations
          </Text>
          <TouchableOpacity
            testID="chat-new-conversation-btn"
            onPress={handleNewConversation}
            className="w-11 h-11 items-center justify-center"
            accessibilityLabel="New conversation"
            accessibilityRole="button"
          >
            <IconSymbol name="plus" size={24} color="#0a7ea4" />
            {!isAuthenticated ? (
              <View
                pointerEvents="none"
                style={{ position: 'absolute', top: 4, right: 4 }}
              >
                <LockChip testID="new-conversation-lock-chip" />
              </View>
            ) : null}
          </TouchableOpacity>
        </View>
        <View testID="chat-empty-state" className="flex-1 items-center justify-center p-8">
          <IconSymbol name="message.fill" size={40} color="#9CA3AF" />
          <Text testID="no-conversations-text" className="text-base font-semibold text-gray-900 dark:text-white mt-4">
            No conversations yet
          </Text>
          <Text testID="chat-empty-state-hint" className="text-sm text-gray-500 dark:text-gray-400 mt-1 text-center">
            Tap + above to start a conversation about a book in your library.
          </Text>
        </View>
        <NewConversationSheet
          isOpen={isSheetOpen}
          onClose={() => setSheetOpen(false)}
          books={libraryBooks}
          isBookEmbedded={isBookEmbedded}
          onSelectBook={handleSelectBookFromSheet}
        />
      </SafeAreaView>
    )
  }

  return (
    <SafeAreaView testID="screen-chat-list" className="flex-1 bg-white dark:bg-[#151718]">
      <View className="px-6 pt-4 pb-2 flex-row items-center justify-between">
        <Text className="text-2xl font-semibold text-gray-900 dark:text-white">
          Conversations
        </Text>
        <TouchableOpacity
          testID="chat-new-conversation-btn"
          onPress={handleNewConversation}
          className="w-11 h-11 items-center justify-center"
          accessibilityLabel="New conversation"
          accessibilityRole="button"
        >
          <IconSymbol name="plus" size={24} color="#0a7ea4" />
          {!isAuthenticated ? (
            <View
              pointerEvents="none"
              style={{ position: 'absolute', top: 4, right: 4 }}
            >
              <LockChip testID="new-conversation-lock-chip" />
            </View>
          ) : null}
        </TouchableOpacity>
      </View>
      <FlatList
        testID="chat-conversation-list"
        data={visibleConversations}
        keyExtractor={(item) => item.id}
        renderItem={({ item }) => {
          // Safe to non-null: visibleConversations is filtered above.
          const book = getBookById(item.bookId)!
          return (
            <ConversationRow
              testID={`conversation-row-${item.id}`}
              conversation={item}
              bookTitle={book.title}
              bookCoverPath={book.coverPath ?? null}
              lastMessage={getLastMessage(item.id)}
              onPress={() =>
                router.push(
                  `/chat/${item.bookId}?cid=${item.id}&from=Conversations`,
                )
              }
              // #60 — the long-press is retained as a power-user shortcut.
              // The swipe-to-delete action is the discoverable affordance
              // wired below; both paths route through the same handleDelete
              // which guards with an Alert.alert confirm before destructive
              // softDeleteConversation.
              onLongPress={() => handleDelete(item.id)}
              onSwipeDelete={() => handleDelete(item.id)}
            />
          )
        }}
        contentContainerClassName="pb-24"
      />
      <NewConversationSheet
        isOpen={isSheetOpen}
        onClose={() => setSheetOpen(false)}
        books={libraryBooks}
        isBookEmbedded={isBookEmbedded}
        onSelectBook={handleSelectBookFromSheet}
      />
    </SafeAreaView>
  )
}
