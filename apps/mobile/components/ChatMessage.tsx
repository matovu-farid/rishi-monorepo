import { ScrollView, Text, View } from 'react-native'
import Animated, { FadeIn, SlideInRight, SlideInLeft } from 'react-native-reanimated'
import { SourceReference } from '@/components/SourceReference'
import type { Message, SourceChunk } from '@/types/conversation'

interface ChatMessageProps {
  message: Message
  onSourcePress?: (source: SourceChunk) => void
}

export function ChatMessage({ message, onSourcePress }: ChatMessageProps) {
  const isUser = message.role === 'user'

  return (
    <Animated.View
      entering={isUser
        ? FadeIn.duration(200).withInitialValues({ opacity: 0 })
        : FadeIn.duration(200).withInitialValues({ opacity: 0 })
      }
      className={`px-4 py-2 ${isUser ? 'items-end' : 'items-start'}`}
    >
      <View
        className={`max-w-[80%] px-4 py-2 ${
          isUser
            ? 'bg-[#0a7ea4] rounded-2xl rounded-br-sm'
            : 'bg-gray-100 dark:bg-[#2A2D2F] rounded-2xl rounded-bl-sm'
        }`}
      >
        <Text
          className={`text-base ${
            isUser ? 'text-white' : 'text-gray-900 dark:text-gray-100'
          }`}
          accessibilityRole="text"
        >
          {message.content}
        </Text>
      </View>

      {/* Source references for assistant messages */}
      {!isUser && message.sourceChunks && message.sourceChunks.length > 0 && (
        <ScrollView
          horizontal
          showsHorizontalScrollIndicator={false}
          className="mt-2"
          contentContainerClassName="gap-2"
        >
          {message.sourceChunks.map((source, index) => (
            <SourceReference
              key={source.chunkId || `source-${index}`}
              source={source}
              onPress={() => onSourcePress?.(source)}
            />
          ))}
        </ScrollView>
      )}
    </Animated.View>
  )
}
