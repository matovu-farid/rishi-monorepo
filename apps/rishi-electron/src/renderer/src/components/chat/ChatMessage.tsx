import { SourceChip } from './SourceChip'
import type { Message } from '@/types/conversation'

interface ChatMessageProps {
  message: Message
  onSourceNavigate: (pageNumber: number) => void
}

export function ChatMessage({ message, onSourceNavigate }: ChatMessageProps) {
  const isUser = message.role === 'user'
  const isLoading = message.role === 'assistant' && message.content === ''

  if (isLoading) {
    return (
      <div className="flex justify-start">
        <div className="bg-gray-100 dark:bg-gray-800 rounded-lg px-4 py-2 max-w-[85%]">
          <div className="flex items-center gap-1">
            <span className="w-2 h-2 rounded-full bg-gray-400 animate-pulse" />
            <span className="w-2 h-2 rounded-full bg-gray-400 animate-pulse [animation-delay:150ms]" />
            <span className="w-2 h-2 rounded-full bg-gray-400 animate-pulse [animation-delay:300ms]" />
          </div>
        </div>
      </div>
    )
  }

  return (
    <div className={`flex ${isUser ? 'justify-end' : 'justify-start'}`}>
      <div
        className={
          isUser
            ? 'bg-blue-600 text-white rounded-lg px-4 py-2 max-w-[85%] ml-auto'
            : 'bg-gray-100 dark:bg-gray-800 rounded-lg px-4 py-2 max-w-[85%]'
        }
      >
        <p className="text-sm whitespace-pre-wrap">{message.content}</p>

        {!isUser && message.sourceChunks && message.sourceChunks.length > 0 ? (
          <div className="flex flex-wrap gap-1 mt-2">
            {message.sourceChunks.map((chunk) => (
              <SourceChip key={chunk.id} chunk={chunk} onNavigate={onSourceNavigate} />
            ))}
          </div>
        ) : null}
      </div>
    </div>
  )
}
