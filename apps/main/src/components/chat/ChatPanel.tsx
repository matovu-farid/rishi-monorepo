import { useEffect, useRef } from 'react';
import {
  Sheet,
  SheetContent,
  SheetHeader,
  SheetTitle,
} from '@components/components/ui/sheet';
import { ScrollArea } from '@components/components/ui/scroll-area';
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
    // Navigate the rendition to the page (epub.js accepts spine index)
    rendition?.display(pageNumber);
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

  return (
    <Sheet open={open} onOpenChange={onOpenChange}>
      <SheetContent side="right" className="w-[440px] flex flex-col">
        <SheetHeader>
          <SheetTitle className="text-sm truncate">
            {bookTitle}
          </SheetTitle>
        </SheetHeader>

        <ScrollArea className="flex-1 px-4">
          {messages.length === 0 && !isLoading ? (
            <div className="flex flex-col items-center justify-center py-16 text-center">
              <h3 className="text-base font-semibold mb-1">
                Ask about this book
              </h3>
              <p className="text-sm text-muted-foreground">
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
        </ScrollArea>

        {error && (
          <p className="px-4 py-1 text-sm text-destructive">
            {error}
          </p>
        )}

        <div className="px-4 pb-4 pt-2">
          <ChatInput onSend={sendMessage} disabled={isLoading} />
        </div>
      </SheetContent>
    </Sheet>
  );
}
