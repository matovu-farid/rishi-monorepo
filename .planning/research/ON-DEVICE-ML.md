# On-Device Embeddings & Vector Search on Mobile

**Researched:** 2026-04-05
**Mode:** Feasibility
**Overall confidence:** MEDIUM-HIGH

---

## Executive Summary

On-device text embedding and vector search on mobile is feasible and the ecosystem has matured significantly. The recommended approach is a **hybrid architecture**: embed on-device using `react-native-executorch` with `all-MiniLM-L6-v2`, store and search vectors locally using `expo-sqlite` with the `sqlite-vec` extension, and fall back to server-side embedding via Cloudflare Workers AI for bulk operations (initial book ingestion of very large libraries).

The key finding is that **React Native ExecuTorch + React Native RAG** from Software Mansion provides a near-turnkey on-device RAG pipeline that closely mirrors what the desktop Tauri app does with `embed_anything` + `hnsw_rs`. This is the strongest option because it is actively maintained, Expo 54 compatible, backed by Meta's ExecuTorch framework, and built by Software Mansion (a core React Native contributor).

Embedding a 300-page book on a modern phone takes an estimated 2-8 minutes depending on device class — acceptable as a one-time background operation, but potentially frustrating for users importing many books at once. The server-side fallback handles that scenario.

---

## Verdict: HYBRID (On-Device Primary, Server Fallback)

**On-device for:** single-book embedding, all vector search queries, offline use
**Server-side for:** bulk library import (10+ books), low-end device fallback

---

## 1. On-Device Text Embedding

### Recommended: react-native-executorch (HIGH confidence)

| Property | Value |
|----------|-------|
| Library | `react-native-executorch` |
| Maintainer | Software Mansion (core RN contributor) |
| Status | Actively maintained, regular releases |
| Expo 54 | Supported (requires `expo-file-system`, dev client) |
| Framework | Meta ExecuTorch (PyTorch on-device runtime) |
| Hook | `useTextEmbeddings` |
| npm | `react-native-executorch` |

**API example:**
```typescript
import { useTextEmbeddings, ALL_MINILM_L6_V2 } from 'react-native-executorch';

const model = useTextEmbeddings({ model: ALL_MINILM_L6_V2 });
const embedding = await model.forward('Chapter 4. Logical Components...');
// Returns: number[] (384 dimensions, normalized)
```

**Supported embedding models:**

| Model | Dimensions | Max Tokens | Size (approx) | Use Case |
|-------|-----------|-----------|---------------|----------|
| all-MiniLM-L6-v2 | 384 | 254 | ~80MB | General purpose - USE THIS |
| all-mpnet-base-v2 | 768 | 382 | ~420MB | Higher quality, 5x larger |
| multi-qa-MiniLM-L6-cos-v1 | 384 | 509 | ~80MB | Semantic search optimized |
| multi-qa-mpnet-base-dot-v1 | 768 | 510 | ~420MB | Semantic search, larger |

**Recommendation:** Use `all-MiniLM-L6-v2` (384 dimensions). This is the same model the desktop app uses via `embed_anything` (see `embed.rs` line 89: `sentence-transformers/all-MiniLM-L6-v2`). Same model = same embedding space = vectors are compatible across desktop and mobile. This is critical for sync.

### Alternative Considered: onnxruntime-react-native (MEDIUM confidence)

| Property | Value |
|----------|-------|
| Library | `onnxruntime-react-native` |
| Version | 1.24.3 (active maintenance) |
| Status | Had critical iOS bug with Expo 54, now fixed via config plugin (PR #27795) |

ONNX Runtime works but has rougher edges with Expo. The iOS model loading bug was only resolved in early 2026. ExecuTorch is the better-supported path for Expo projects.

### Alternative Considered: react-native-transformers (LOW confidence)

**Archived as of July 2025.** Do not use. Was a wrapper around onnxruntime-react-native that is no longer maintained.

### Alternative Considered: Apple NLP Framework (LOW confidence)

Callstack published work on using Apple's built-in NLP framework for embeddings in React Native. iOS-only, non-portable, and the embedding dimensions/model are opaque. Not suitable for cross-platform or for matching the desktop app's embedding space.

---

## 2. Embedding Model Selection

### Use all-MiniLM-L6-v2 (HIGH confidence)

**Rationale:**
1. **Same model as desktop app** - The Tauri app uses `sentence-transformers/all-MiniLM-L6-v2`. Using the same model means embeddings are interchangeable. If you sync vectors between desktop and mobile, they must come from the same model.
2. **Small enough for mobile** - ~80MB on disk, ~22M parameters, 6 transformer layers. Fits comfortably in mobile memory.
3. **384 dimensions** - Small vector size means fast search and low storage overhead.
4. **Well-tested on mobile** - Multiple libraries (ExecuTorch, ONNX Runtime) ship with this model pre-configured.

**Known limitation:** Max 254 tokens with ExecuTorch (vs 256 with the original model). Book chunks should be kept under ~200 tokens to leave room for special tokens.

**Performance estimates for all-MiniLM-L6-v2 on mobile:**

| Metric | Flagship (iPhone 15/S24) | Mid-range (iPhone 12/Pixel 7) |
|--------|--------------------------|-------------------------------|
| Single chunk (~80 tokens) | ~20-40ms | ~40-80ms |
| Model load time | ~1-2s | ~2-4s |
| Memory footprint | ~150-200MB | ~150-200MB |

These are estimates based on general ExecuTorch benchmarks and ONNX Runtime mobile data. The initial model load incurs a one-time cost (up to 2x first inference). Confidence: MEDIUM (no published mobile-specific benchmarks for this exact combination).

---

## 3. Vector Search on Mobile

### Recommended: expo-sqlite + sqlite-vec (HIGH confidence)

**This is the strongest option** because expo-sqlite is already part of the Expo SDK and sqlite-vec is officially supported as a bundled extension.

**Setup:**
```json
// app.json
{
  "expo": {
    "plugins": [
      ["expo-sqlite", { "withSQLiteVecExtension": true }]
    ]
  }
}
```

```typescript
import * as SQLite from 'expo-sqlite';

const db = await SQLite.openDatabaseAsync('rishi.db');
const ext = SQLite.bundledExtensions['sqlite-vec'];
await db.loadExtensionAsync(ext.libPath, ext.entryPoint);

// Create vector table
await db.execAsync(`
  CREATE VIRTUAL TABLE IF NOT EXISTS vec_chunks USING vec0(
    embedding float[384]
  );
`);

// Insert vectors
await db.runAsync(
  'INSERT INTO vec_chunks(rowid, embedding) VALUES (?, ?)',
  [chunkId, vectorBlob]
);

// Search (brute-force KNN)
const results = await db.getAllAsync(`
  SELECT rowid, distance
  FROM vec_chunks
  WHERE embedding MATCH ?
  ORDER BY distance
  LIMIT 10
`, [queryVectorBlob]);
```

**Important caveat:** sqlite-vec uses **brute-force KNN only** (no HNSW index). For the expected scale of a reading app (hundreds to low thousands of chunks per book, maybe 10-50 books = 5,000-50,000 total vectors), brute-force search over 384-dimensional vectors is fast enough:

| Vector Count | Search Time (brute-force, 384d) | Acceptable? |
|-------------|-------------------------------|-------------|
| 1,000 | <5ms | Yes |
| 10,000 | ~10-30ms | Yes |
| 50,000 | ~50-150ms | Marginal |
| 100,000+ | ~200-500ms+ | No |

For a reading app with 20-30 books, you are in the 10,000-30,000 range. Brute-force is fine.

### Alternative: expo-vector-search (MEDIUM confidence)

| Property | Value |
|----------|-------|
| Library | `expo-vector-search` |
| Algorithm | HNSW (via USearch C++ library) |
| Performance | Sub-millisecond search on 10,000 vectors |
| Maturity | v0.5.0, 5 releases |

This library uses actual HNSW (like the desktop app's `hnsw_rs`) and is dramatically faster than brute-force. However:
- It is a separate native module (more build complexity)
- Less mature than expo-sqlite
- Would need a separate storage mechanism for the vectors themselves
- No clear Expo 54 compatibility confirmation

**Use this if:** the app scales to 100K+ vectors and brute-force becomes too slow.

### Alternative: React Native RAG's built-in VectorStore (MEDIUM confidence)

The `@react-native-rag/op-sqlite` package provides a VectorStore that persists to SQLite via OP-SQLite. This is part of the React Native RAG ecosystem. It may be the path of least resistance if using the full RAG pipeline, but it adds OP-SQLite as a dependency alongside expo-sqlite (two SQLite libraries).

### Alternative: vectorlite SQLite extension (LOW confidence)

Uses HNSW and is 8-80x faster than brute-force. However, it is not bundled with expo-sqlite and would require custom native module integration. Not worth the effort given the scale of this app.

---

## 4. Realistic Performance: Embedding a 300-Page Book

### Estimation

A 300-page book contains roughly:
- **75,000-120,000 words** (~250-400 words/page)
- **100,000-160,000 tokens** (1 token per ~0.75 words for English)
- At **200 tokens per chunk** with 10% overlap: **550-880 chunks**

**Embedding time estimates:**

| Device Class | Per-Chunk | 700 Chunks | Notes |
|-------------|-----------|------------|-------|
| Flagship (2024+) | ~30ms | ~21s | Excellent |
| Mid-range (2022+) | ~60ms | ~42s | Good |
| Budget/older | ~120ms | ~84s | Acceptable |

These estimates assume batch-sequential processing. The first inference is ~2x slower due to model warm-up.

**Verdict:** A single book can be embedded in under 2 minutes on most modern phones. This is acceptable as a background task triggered when the user imports a book. Show a progress indicator and allow the user to start reading while embedding continues.

**For bulk import (10+ books):** Server-side is strongly recommended. Embedding 10 books on a mid-range phone would take ~7 minutes and drain significant battery. The server can do it in seconds.

### Storage Requirements

| Component | Per Book (700 chunks) | 30 Books |
|-----------|----------------------|----------|
| Vectors (384d float32) | ~1.05 MB | ~31.5 MB |
| Chunk text | ~350 KB | ~10.5 MB |
| Metadata | ~50 KB | ~1.5 MB |
| **Total** | **~1.5 MB** | **~43.5 MB** |

Storage is negligible. The book files themselves (EPUB/PDF) dwarf the vector data.

---

## 5. Server-Side Alternative

### Cloudflare Workers AI + Vectorize

The existing Cloudflare Worker can be extended with embedding and vector search endpoints.

**Embedding endpoint:**
```typescript
// In worker
app.post('/api/embed', requireWorkerAuth, async (c) => {
  const { chunks } = await c.req.json();
  const ai = c.env.AI;
  const embeddings = await ai.run('@cf/baai/bge-small-en-v1.5', {
    text: chunks
  });
  return c.json({ embeddings: embeddings.data });
});
```

| Property | Value |
|----------|-------|
| Model | `@cf/baai/bge-small-en-v1.5` (384 dimensions) |
| Pricing | $0.011 per 1,000 Neurons (~free for personal use) |
| Latency | ~50-100ms per batch at edge |
| Dimensions | 384 (matches all-MiniLM-L6-v2!) |

**IMPORTANT:** `bge-small-en-v1.5` produces 384-dimensional embeddings but they are NOT in the same embedding space as `all-MiniLM-L6-v2`. You cannot mix vectors from different models. If using server-side embedding, ALL vectors for a given book must come from the same model.

**Options for server-side compatibility:**
1. **Use bge-small on server, store separately** - Server vectors are only for server-side search. Mobile re-embeds locally for local search. Wasteful but simple.
2. **Run all-MiniLM-L6-v2 on the Worker** - Use ONNX Runtime on Workers (experimental) or a custom inference endpoint. Complex.
3. **Hybrid: server embeds, mobile downloads vectors** - Server embeds with bge-small, stores in Vectorize, mobile downloads pre-computed vectors for local brute-force search. Mobile never embeds locally. Loses offline-first capability for new books.

### Cloudflare Vectorize

| Property | Value |
|----------|-------|
| Service | Cloudflare Vectorize |
| Dimensions | Configurable (384 for bge-small) |
| Index type | HNSW |
| Pricing | Free tier: 5M vectors, 30M queries/month |
| Integration | Native Workers AI binding |

Vectorize provides server-side HNSW search. Useful for cross-device search (search across all books from any device) but requires network.

---

## 6. Recommended Architecture: Hybrid

### Primary Path: On-Device (offline-capable)

```
Book imported
    |
    v
Text extraction (EPUB/PDF parser)
    |
    v
Chunking (200 tokens, 10% overlap)
    |
    v
react-native-executorch (all-MiniLM-L6-v2)
    |
    v
expo-sqlite + sqlite-vec (store vectors + metadata)
    |
    v
User asks question
    |
    v
Embed query (same model, ~30ms)
    |
    v
sqlite-vec KNN search (top-10, ~10ms)
    |
    v
Retrieve chunk text from SQLite
    |
    v
Send context + question to Worker LLM endpoint
    |
    v
Stream answer back
```

### Fallback Path: Server-Side (bulk import)

```
User imports 10+ books OR device is low-end
    |
    v
Upload book text chunks to Worker
    |
    v
Worker embeds via Workers AI (bge-small-en-v1.5)
    |
    v
Worker stores in Vectorize (server search)
    OR
    Worker returns vectors to mobile for local storage
    |
    v
Mobile stores vectors in sqlite-vec
```

### Key Design Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Primary embedding location | On-device | Privacy, offline, no API cost, matches user preference |
| Embedding model | all-MiniLM-L6-v2 | Same as desktop, 384d, small enough for mobile |
| Vector storage | expo-sqlite + sqlite-vec | First-party Expo support, no extra native modules |
| Search algorithm | Brute-force KNN | Sufficient for <50K vectors, no HNSW complexity |
| Bulk fallback | Cloudflare Workers AI | Fast, cheap, handles 10+ book imports |
| LLM inference | Server-side (existing Worker) | LLMs are too large for mobile; already have the endpoint |

---

## 7. React Native RAG: The Turnkey Option

Software Mansion's `react-native-rag` ecosystem deserves special attention. It provides:

- `react-native-rag` - Core: TextSplitter, VectorStore, Embeddings interfaces
- `@react-native-rag/executorch` - On-device embedding + LLM via ExecuTorch
- `@react-native-rag/op-sqlite` - Persistent vector storage via OP-SQLite

This is essentially a pre-built RAG pipeline for React Native. The tradeoff:

**Pros:**
- Fastest path to a working RAG pipeline
- Handles chunking, embedding, storage, and retrieval
- Uses `useRAG` hook for simple integration
- Built by Software Mansion (high quality, maintained)

**Cons:**
- Adds OP-SQLite dependency (the app already needs expo-sqlite for other data)
- Young library (announced July 2025, ~v0.2.0)
- Less control over chunking strategy
- May not support custom metadata (book_id, page_number) without extension

**Recommendation:** Evaluate `react-native-rag` first. If it supports the metadata structure needed (chunk ID, book ID, page number), use it. If not, use the individual components: `react-native-executorch` for embedding + `expo-sqlite`/`sqlite-vec` for storage and search.

---

## 8. Pitfalls and Risks

### Critical

**Pitfall: Mixing embedding models breaks search.**
The desktop uses `all-MiniLM-L6-v2`. If the server uses `bge-small-en-v1.5`, vectors from different models cannot be compared. Either use the same model everywhere or maintain separate vector indices.

**Pitfall: ExecuTorch requires dev client, not Expo Go.**
`react-native-executorch` includes native code. Development must use `npx expo prebuild` + custom dev client. This is standard for any non-trivial Expo app but worth noting.

**Pitfall: Model download size on first launch.**
The `all-MiniLM-L6-v2` model (~80MB) must be bundled or downloaded. Bundling inflates the app binary. Downloading on first use requires handling the download flow gracefully. ExecuTorch supports both approaches.

### Moderate

**Pitfall: Memory pressure on low-end devices.**
The embedding model consumes ~150-200MB of RAM during inference. On devices with 3-4GB total RAM, this could cause background app kills. Mitigation: load the model only when embedding, unload after.

**Pitfall: sqlite-vec brute-force scaling.**
If the app grows to support 100+ books (100K+ vectors), brute-force search will become slow. Mitigation: partition vectors by book (search only within selected books) or migrate to expo-vector-search (HNSW).

**Pitfall: Chunking strategy differences between desktop and mobile.**
The desktop app chunks via `embed_anything`'s `process_chunks`. The mobile app will use a different chunker. Different chunking = different retrieval quality even with the same model. Mitigation: implement identical chunking logic or accept minor quality differences.

### Minor

**Pitfall: Initial embedding blocks UI.**
Embedding is CPU-intensive. Running on the JS thread will freeze the UI. Mitigation: ExecuTorch runs inference on a background thread by default. Ensure the chunking and SQLite writes are also off the main thread.

**Pitfall: Battery drain during bulk embedding.**
Embedding hundreds of chunks is CPU-intensive. On battery, this could be noticeable. Mitigation: show a warning for large books, offer to defer embedding to when plugged in, or use server fallback.

---

## 9. Implementation Phases

**Phase 1: Basic on-device RAG**
- Install `react-native-executorch` and `expo-sqlite` with `sqlite-vec`
- Implement text chunking (200 tokens, 10% overlap)
- Embed chunks with `all-MiniLM-L6-v2` via `useTextEmbeddings`
- Store vectors in sqlite-vec
- Implement KNN search for query
- Send retrieved context to Worker LLM endpoint

**Phase 2: Server fallback**
- Add embedding endpoint to Worker (Workers AI, bge-small or hosted MiniLM)
- Add bulk import flow for 10+ books
- Handle vector download and local storage

**Phase 3: Cross-device sync**
- Sync vector indices between desktop and mobile
- Since both use all-MiniLM-L6-v2, vectors are compatible
- Sync chunk text and metadata via Worker

---

## 10. Confidence Assessment

| Area | Confidence | Reason |
|------|-----------|--------|
| react-native-executorch viability | HIGH | Maintained by Software Mansion, Expo 54 support confirmed, official docs |
| all-MiniLM-L6-v2 on mobile | HIGH | Multiple implementations exist, model is well-characterized |
| expo-sqlite + sqlite-vec | HIGH | First-party Expo plugin support, officially documented |
| Embedding performance estimates | MEDIUM | Extrapolated from general benchmarks, no published mobile-specific data for ExecuTorch embeddings |
| react-native-rag maturity | MEDIUM | Announced July 2025, young library, API may change |
| Server-side Workers AI | HIGH | Cloudflare official documentation, well-established |
| Bulk book embedding time | MEDIUM | Calculated from per-chunk estimates, not measured |

---

## Sources

- [react-native-executorch docs](https://docs.swmansion.com/react-native-executorch/)
- [useTextEmbeddings hook](https://docs.swmansion.com/react-native-executorch/docs/hooks/natural-language-processing/useTextEmbeddings)
- [react-native-rag GitHub](https://github.com/software-mansion-labs/react-native-rag)
- [Introducing React Native RAG](https://swmansion.com/blog/introducing-react-native-rag-fbb62efa4991)
- [expo-sqlite docs (sqlite-vec)](https://docs.expo.dev/versions/latest/sdk/sqlite/)
- [sqlite-vec GitHub](https://github.com/asg017/sqlite-vec)
- [expo-vector-search GitHub](https://github.com/mensonones/expo-vector-search)
- [onnxruntime-react-native npm](https://www.npmjs.com/package/onnxruntime-react-native)
- [ONNX Runtime Expo 54 iOS bug (resolved)](https://github.com/microsoft/onnxruntime/issues/27062)
- [Cloudflare Workers AI pricing](https://developers.cloudflare.com/workers-ai/platform/pricing/)
- [Cloudflare Vectorize docs](https://developers.cloudflare.com/vectorize/)
- [all-MiniLM-L6-v2 on HuggingFace](https://huggingface.co/sentence-transformers/all-MiniLM-L6-v2)
- [Expo blog: AI models with ExecuTorch](https://expo.dev/blog/how-to-run-ai-models-with-react-native-executorch)
- [Callstack: Apple embeddings in React Native](https://www.callstack.com/blog/on-device-ai-introducing-apple-embeddings-in-react-native)
