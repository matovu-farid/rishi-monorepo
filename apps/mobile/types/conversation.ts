export interface TextChunk {
  id: string // UUID
  bookId: string
  chunkIndex: number // position in book
  text: string // chunk content (~500 chars)
  chapter: string | null // chapter/section label
  createdAt: number // Unix timestamp ms
}

export interface SourceChunk {
  chunkId: string
  text: string // snippet (first 100 chars of chunk)
  chapter: string | null
  cfiRange?: string // EPUB CFI if available
}

export interface Conversation {
  id: string // UUID
  bookId: string
  title: string // auto-generated from first user message (first 50 chars)
  createdAt: number
  updatedAt: number
}

export interface Message {
  id: string // UUID
  conversationId: string
  role: 'user' | 'assistant'
  content: string
  sourceChunks: SourceChunk[] | null // JSON parsed, only on assistant messages
  createdAt: number
  updatedAt: number
}
