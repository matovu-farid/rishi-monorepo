import { useEffect, useRef } from 'react';
import { useChat } from '@/hooks/useChat';
import { ChatMessage } from './ChatMessage';
import { ChatInput } from './ChatInput';
import type { Rendition } from 'epubjs/types';
import type { Message } from '@/types/conversation';

interface ChatPanelProps {
  bookId: number;
  bookSyncId: string;
  bookTitle: string;
  rendition: Rendition | null;
  open: boolean;
  onOpenChange: (open: boolean) => void;
}

export function ChatPanel({
  bookId,
  bookSyncId,
  bookTitle,
  rendition,
  open,
  onOpenChange,
}: ChatPanelProps) {
  const { messages, isLoading, error, sendMessage } = useChat(bookId, bookSyncId, bookTitle);
  const scrollEndRef = useRef<HTMLDivElement>(null);

  // Auto-scroll to bottom on new messages
  useEffect(() => {
    scrollEndRef.current?.scrollIntoView({ behavior: 'smooth' });
  }, [messages.length, isLoading]);

  const handleSourceNavigate = (pageNumber: number) => {
    void rendition?.display(pageNumber);
  };

  // Build the loading message placeholder
  const loadingMessage: Message | null = isLoading
    ? {
        id: '__loading__',
        conversationId: '',
        role: 'assistant',
        content: '',
        sourceChunks: null,
        createdAt: Date.now(),
      }
    : null;

  if (!open) return null;

  return (
    <div className="fixed inset-y-0 right-0 z-50 w-[440px] bg-white dark:bg-gray-900 border-l border-gray-200 dark:border-gray-700 shadow-xl flex flex-col">
      {/* Header */}
      <div className="flex items-center justify-between px-4 py-3 border-b border-gray-200 dark:border-gray-700">
        <h2 className="text-sm font-medium truncate">{bookTitle}</h2>
        <button
          onClick={() => onOpenChange(false)}
          className="p-1 rounded hover:bg-gray-100 dark:hover:bg-gray-800"
          aria-label="Close"
        >
          &times;
        </button>
      </div>

      {/* Messages */}
      <div className="flex-1 overflow-y-auto px-4">
        {messages.length === 0 && !isLoading ? (
          <div className="flex flex-col items-center justify-center py-16 text-center">
            <h3 className="text-base font-semibold mb-1">Ask about this book</h3>
            <p className="text-sm text-gray-500">
              Ask a question and get answers grounded in the book's content.
            </p>
          </div>
        ) : (
          <div className="flex flex-col gap-3 py-2">
            {messages.map((msg) => (
              <ChatMessage
                key={msg.id}
                message={msg}
                onSourceNavigate={handleSourceNavigate}
              />
            ))}
            {loadingMessage && (
              <ChatMessage
                message={loadingMessage}
                onSourceNavigate={handleSourceNavigate}
              />
            )}
            <div ref={scrollEndRef} />
          </div>
        )}
      </div>

      {error && (
        <p className="px-4 py-1 text-sm text-red-500">{error}</p>
      )}

      <div className="px-4 pb-4 pt-2">
        <ChatInput onSend={sendMessage} disabled={isLoading} />
      </div>
    </div>
  );
}
