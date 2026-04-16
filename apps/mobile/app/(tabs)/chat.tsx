import { useCallback, useState } from 'react'
import { View, FlatList, TouchableOpacity, Alert, Text } from 'react-native'
import { SafeAreaView } from 'react-native-safe-area-context'
import { useRouter, useFocusEffect } from 'expo-router'
import { IconSymbol } from '@/components/ui/icon-symbol'
import { ConversationRow } from '@/components/ConversationRow'
import {
  getAllConversations,
  getMessages,
  softDeleteConversation,
} from '@/lib/conversation-storage'
import { getBookById } from '@/lib/book-storage'
import { getBooks } from '@/lib/book-storage'
import { isBookEmbedded } from '@/lib/rag/vector-store'
import type { Conversation } from '@/types/conversation'

export default function ConversationsScreen() {
  const router = useRouter()
  const [conversations, setConversations] = useState<Conversation[]>([])

  const loadConversations = useCallback(() => {
    setConversations(getAllConversations())
  }, [])

  useFocusEffect(
    useCallback(() => {
      loadConversations()
    }, [loadConversations])
  )

  const handleNewConversation = useCallback(() => {
    // Get all books that have been embedded
    const allBooks = getBooks()
    const embeddedBooks = allBooks.filter(b => isBookEmbedded(b.id))

    if (embeddedBooks.length === 0) {
      Alert.alert(
        'No Books Ready',
        'Open a book first to prepare it for AI conversations.'
      )
      return
    }

    const buttons = embeddedBooks.slice(0, 10).map(book => ({
      text: book.title,
      onPress: () => router.push(`/chat/${book.id}`),
    }))
    buttons.push({ text: 'Cancel', onPress: () => {} })

    Alert.alert('Start Conversation', 'Choose a book:', buttons)
  }, [router])

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

  if (conversations.length === 0) {
    return (
      <SafeAreaView className="flex-1 bg-white dark:bg-[#151718]">
        <View className="px-6 pt-4 pb-2 flex-row items-center justify-between">
          <Text testID="conversations-title" className="text-2xl font-semibold text-gray-900 dark:text-white">
            Conversations
          </Text>
          <TouchableOpacity
            testID="new-conversation-button"
            onPress={handleNewConversation}
            className="w-11 h-11 items-center justify-center"
            accessibilityLabel="New conversation"
            accessibilityRole="button"
          >
            <IconSymbol name="plus" size={24} color="#0a7ea4" />
          </TouchableOpacity>
        </View>
        <View className="flex-1 items-center justify-center p-8">
          <IconSymbol name="message.fill" size={40} color="#9CA3AF" />
          <Text testID="no-conversations-text" className="text-base font-semibold text-gray-900 dark:text-white mt-4">
            No conversations yet
          </Text>
          <Text className="text-sm text-gray-500 dark:text-gray-400 mt-1 text-center">
            Open a book and tap the AI icon to start a conversation.
          </Text>
        </View>
      </SafeAreaView>
    )
  }

  return (
    <SafeAreaView className="flex-1 bg-white dark:bg-[#151718]">
      <View className="px-6 pt-4 pb-2 flex-row items-center justify-between">
        <Text className="text-2xl font-semibold text-gray-900 dark:text-white">
          Conversations
        </Text>
        <TouchableOpacity
          onPress={handleNewConversation}
          className="w-11 h-11 items-center justify-center"
          accessibilityLabel="New conversation"
          accessibilityRole="button"
        >
          <IconSymbol name="plus" size={24} color="#0a7ea4" />
        </TouchableOpacity>
      </View>
      <FlatList
        data={conversations}
        keyExtractor={(item) => item.id}
        renderItem={({ item }) => {
          const book = getBookById(item.bookId)
          return (
            <ConversationRow
              conversation={item}
              bookTitle={book?.title ?? 'Unknown Book'}
              bookCoverPath={book?.coverPath ?? null}
              lastMessage={getLastMessage(item.id)}
              onPress={() => router.push(`/chat/${item.bookId}`)}
              onLongPress={() => handleDelete(item.id)}
            />
          )
        }}
        contentContainerClassName="pb-24"
      />
    </SafeAreaView>
  )
}
