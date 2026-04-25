export interface SourceChunk {
  id: number;
  text: string;
  pageNumber: number;
  chapter?: string;
}

export interface Message {
  id: string;
  conversationId: string;
  role: 'user' | 'assistant';
  content: string;
  sourceChunks: SourceChunk[] | null;
  createdAt: number;
}

export interface Conversation {
  id: string;
  bookId: string;
  title: string;
  createdAt: number;
  updatedAt: number;
  messages: Message[];
}
