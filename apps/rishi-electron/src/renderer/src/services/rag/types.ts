export interface SemanticChunk {
  chunkId: number
  bookId: number
  pageNumber: number
  text: string
  distance: number
}

export interface TextMatch {
  chunkId: number
  bookId: number
  pageNumber: number
  text: string
  snippet: string
}

export interface RagIpcChannels {
  searchVectors(
    name: string,
    query: number[],
    dim: number,
    k: number
  ): Promise<Array<{ id: number; distance: number }>>
  getTextFromVectorId(
    vectorId: number
  ): Promise<{ id: number; pageNumber: number; bookId: number; data: string } | undefined>
  searchBookText(
    query: string,
    bookId: number
  ): Promise<
    Array<{ id: number; pageNumber: number; bookId: number; data: string; snippet: string }>
  >
  hasVectorsForBook(bookId: number): Promise<boolean>
}

export interface RagServiceDeps {
  ipc: RagIpcChannels
  embed: (text: string) => Promise<number[]>
}

export interface RagService {
  searchSemantic(query: string, bookId: number, k: number): Promise<SemanticChunk[]>
  searchText(query: string, bookId: number): Promise<TextMatch[]>
  isIndexed(bookId: number): Promise<boolean>
}
