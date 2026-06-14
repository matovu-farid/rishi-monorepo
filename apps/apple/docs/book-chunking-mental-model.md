# Book Chunking — Mental Model

> Conceptual model only. No file paths, no APIs, no plumbing.

## TL;DR

A book becomes a **flat sequence of `(page, paragraph)` pairs**, indexed by position.
Everything downstream (TTS, prewarm, highlight, search) is just **index arithmetic over that sequence**, with the page number tagged along as a coordinate.

| Question | Answer |
| --- | --- |
| What is a chunk? | A paragraph. Identity = its index. Coordinate = its page. |
| Is it format-agnostic? | **Yes downstream.** Format only matters at extraction and footer detection. |
| What does the queue carry? | `[(page, text)]` plus a cursor. Nothing richer. |
| What's the size ceiling? | 4 096 chars per chunk, with sentence → word fallback. |
| What about page chrome (footers, page numbers, footnotes)? | **Stripped before chunking**, PDF-only, behind a toggle. The chunker never sees them. |
| Are sub-chunks visible? | **No.** Embedding-time subdivision is invisible to playback/highlight — only the indexer sees it. |

---

## 1. The Layers

The pipeline is four concentric responsibilities. The format dies at the chunker's doorstep; the page chrome dies just before that, but only for PDF.

```mermaid
flowchart TD
    classDef extract fill:#fff1f2,stroke:#be123c,color:#881337,stroke-width:2px
    classDef dechrome fill:#fef3c7,stroke:#b45309,color:#78350f,stroke-width:2px
    classDef normalize fill:#eff6ff,stroke:#1d4ed8,color:#1e3a8a,stroke-width:2px
    classDef consume fill:#ecfdf5,stroke:#047857,color:#064e3b,stroke-width:2px
    classDef ghost fill:transparent,stroke:transparent,color:#475569

    subgraph EXTRACT["1 · Extract  ·  format-aware"]
        direction LR
        E["`📖 **EPUB resource**
        _HTML in_`"]:::extract
        P["`📄 **PDF page**
        _text + layout in_`"]:::extract
    end

    subgraph DECHROME["2 · De-chrome  ·  PDF-only, optional"]
        F["`🧹 **Footer detector**
        drops page numbers,
        running headers, footnotes`"]:::dechrome
    end

    subgraph NORMALIZE["3 · Normalize  ·  format-agnostic"]
        C["`¶ **Paragraph Chunker**
        String → [String] (per page)`"]:::normalize
    end

    subgraph CONSUME["4 · Consume  ·  index-driven"]
        direction LR
        Q["`🧵 **Paragraph queue**
        indexed [0..n)
        each carries its page`"]:::consume
        TTS["`🔊 **TTS**
        playback`"]:::consume
        PRE["`🔥 **Prewarm**
        next N`"]:::consume
        HL["`🖍️ **Reader**
        highlight`"]:::consume
        IDX["`🔎 **Indexer**
        embeds for search`"]:::consume
    end

    E --> C
    P --> F
    F --> C
    C --> Q
    Q --> TTS
    Q --> PRE
    Q --> HL
    Q --> IDX

    NOTE["`_Format dies at the chunker.
    Chrome dies one step earlier — but only for PDF._`"]:::ghost
    NORMALIZE -.- NOTE
```

**Boundary discipline**

- Layer 1 knows the format. Layer 2 only runs for PDF and is behind a policy toggle. Layer 3 and 4 do not know either.
- Layer 3 is a **pure function**: `String → [String]`.
- Layer 4 only sees a `passageId` (the index) and a page number. No paragraph object, no layout, no font info.

---

## 2. What a Chunk Is

A chunk is not a sentence, a page, or a section. It is a **paragraph with an index and a page coordinate**.

```mermaid
flowchart LR
    classDef card fill:#fefce8,stroke:#a16207,color:#713f12,stroke-width:2px,rx:8,ry:8
    classDef rule fill:#f8fafc,stroke:#475569,color:#0f172a,stroke-width:1px

    CHUNK["`**Chunk**
    ─────────────
    📝 text : _String_
    🔢 index : _Int_  (a.k.a. **passageId**)
    📄 page : _Int_  (coordinate, not identity)`"]:::card

    R1["`✓ one paragraph, semantic unit`"]:::rule
    R2["`✓ length ≤ **4 096** chars`"]:::rule
    R3["`✓ never empty / whitespace-only`"]:::rule
    R4["`✓ never page chrome (numbers, headers, footnotes)`"]:::rule
    R5["`✓ subdivide by sentence, then word — _never mid-word_`"]:::rule
    R6["`✓ **index is stable** for the session`"]:::rule

    CHUNK --- R1
    CHUNK --- R2
    CHUNK --- R3
    CHUNK --- R4
    CHUNK --- R5
    CHUNK --- R6
```

Page is a **coordinate**, not identity — two paragraphs from the same page have different indices and are different chunks. Identity is the index.

---

## 3. Format Awareness — Where It Lives

Format-specific surface area is concentrated in two places: how raw text comes out, and (for PDF only) how page chrome gets stripped before chunking. The chunker itself is shared.

```mermaid
flowchart LR
    classDef aware fill:#fff1f2,stroke:#be123c,color:#881337,stroke-width:2px
    classDef dechrome fill:#fef3c7,stroke:#b45309,color:#78350f,stroke-width:2px
    classDef shared fill:#eff6ff,stroke:#1d4ed8,color:#1e3a8a,stroke-width:2px
    classDef out fill:#ecfdf5,stroke:#047857,color:#064e3b,stroke-width:2px

    subgraph AWARE["⚠️ Format-aware  ·  divergent"]
        direction TB
        EPUB["`📖 **EPUB** — HTML`"]:::aware
        PDF["`📄 **PDF** — text + layout`"]:::aware
        H["`✂️ split on **&lt;p&gt;** tags
        + strip inline HTML`"]:::aware
        B["`✂️ split on **blank lines**`"]:::aware
        EPUB --> H
        PDF --> B
    end

    subgraph CHROME["🧹 De-chrome  ·  PDF-only, opt-in"]
        FD["`drop page numbers,
        running headers,
        footnotes`"]:::dechrome
    end

    subgraph SHARED["🔀 Format-agnostic  ·  convergent"]
        direction TB
        SUB["`**Subdivide if &gt; 4 096**
        sentence → word fallback`"]:::shared
        TRIM["`🧽 **Trim & drop empties**`"]:::shared
        SUB --> TRIM
    end

    H --> SUB
    B --> FD
    FD --> SUB
    TRIM --> OUT["`➡️ **[(page, text)]** paragraphs`"]:::out
```

**Things that do NOT know the file format**

| | Component | Sees |
| :---: | --- | --- |
| 🧵 | the queue | `[(page, text)]` + index |
| 🔊 | the TTS engine | one string at a time |
| 🔥 | the prewarmer | next N strings |
| 🔌 | the reader-to-audio bridge | indices only |
| 🖍️ | the highlight system | indices only |
| 🔎 | the search indexer | `(page, text)` tuples |

---

## 4. The Footer Detector (PDF only)

PDF has chrome that EPUB does not: page numbers, running headers, footnote blocks. If we let them through, TTS reads "Page 47" between paragraphs and search returns hits on chapter titles repeated 300 times.

The detector runs **before** chunking and emits a **mask** — a set of paragraph slots to drop per page. It does not modify text, it only marks for removal. It is behind a policy toggle and only engages when layout information is available.

```mermaid
flowchart TD
    classDef io fill:#0f172a,stroke:#0f172a,color:#f8fafc,stroke-width:2px
    classDef strat fill:#fef3c7,stroke:#b45309,color:#78350f,stroke-width:2px
    classDef join fill:#eff6ff,stroke:#1d4ed8,color:#1e3a8a,stroke-width:2px
    classDef emit fill:#ecfdf5,stroke:#047857,color:#064e3b,stroke-width:2px

    IN(["▶ pages with layout"]):::io

    S1["`📌 **Repetition**
    same text in same
    y-band across ≥30%
    of pages`"]:::strat
    S2["`📎 **Suffix**
    same trailing paragraph
    across ≥30% of pages
    _(text-only, no layout needed)_`"]:::strat
    S3["`🔬 **Footnote**
    below body cluster,
    smaller font, oversized gap`"]:::strat

    NORM["`🔢 normalize digits
    so '_Page 47_' and '_Page 48_'
    hash to the same key`"]:::join

    EXPAND["`↔️ expand to line-mates
    on the same baseline`"]:::join

    MASK[("🗑️ paragraph-index mask
    per page")]:::emit

    OUT(["⏹ clean pages → chunker"]):::io

    IN --> NORM
    NORM --> S1
    NORM --> S2
    NORM --> S3
    S1 --> EXPAND
    S2 --> EXPAND
    S3 --> EXPAND
    EXPAND --> MASK
    MASK --> OUT
```

**Properties**

- Three strategies vote independently; their masks are **unioned** — any one is enough to drop a paragraph.
- The mask is keyed by **paragraph slot**, not raw text. So a body paragraph that happens to end with "Page 7" is safe — only paragraphs whose normalized text matches a flagged item on the same page get dropped.
- EPUB does not go through here today. The text-only suffix strategy could in principle apply to EPUB, but it only runs alongside the layout strategies.
- The detector is **stateless and pure** — same pages in, same mask out.

---

## 5. The Chunker's Internal Decision Tree

Subdivision is a **fallback ladder**, never the primary mode. For a normal book, every chunk falls out of the first branch untouched.

```mermaid
flowchart TD
    classDef io fill:#0f172a,stroke:#0f172a,color:#f8fafc,stroke-width:2px
    classDef decide fill:#fef3c7,stroke:#b45309,color:#78350f,stroke-width:2px
    classDef step fill:#eff6ff,stroke:#1d4ed8,color:#1e3a8a,stroke-width:2px
    classDef emit fill:#ecfdf5,stroke:#047857,color:#064e3b,stroke-width:2px

    IN(["▶ string in"]):::io

    Q1{"`contains **&lt;p** ?`"}:::decide
    HTML["`🏷️ split on &lt;p&gt; tags
    + strip inline HTML`"]:::step
    TEXT["`📝 split on blank lines`"]:::step

    EACH(["`🔁 **for each paragraph**`"]):::step
    SIZE{"`size ≤ **4 096** ?`"}:::decide
    KEEP["`✅ emit as-is`"]:::emit

    SENT["`✂️ split by sentence,
    greedy pack`"]:::step
    SENTSIZE{"`any sentence
    still &gt; 4 096 ?`"}:::decide
    WORD["`✂️ split on word
    boundaries`"]:::step

    OUT(["⏹ [String] out"]):::io

    IN --> Q1
    Q1 -- yes --> HTML
    Q1 -- no --> TEXT
    HTML --> EACH
    TEXT --> EACH
    EACH --> SIZE
    SIZE -- yes --> KEEP
    SIZE -- no --> SENT
    SENT --> SENTSIZE
    SENTSIZE -- no --> KEEP
    SENTSIZE -- yes --> WORD
    WORD --> KEEP
    KEEP --> OUT
```

---

## 6. Consumer's View — Tape, Cursor, and Page Tag

Downstream, the book is **a tape, a cursor, and a page tag riding alongside each cell**. Advance the cursor, play the chunk at it, prewarm a window ahead, show the page in the UI.

```mermaid
flowchart LR
    classDef tape fill:#f8fafc,stroke:#475569,color:#0f172a,stroke-width:1px,rx:4,ry:4
    classDef active fill:#fde68a,stroke:#b45309,color:#78350f,stroke-width:3px,rx:4,ry:4
    classDef ahead fill:#fecaca,stroke:#b91c1c,color:#7f1d1d,stroke-width:2px,rx:4,ry:4
    classDef cursor fill:#0f172a,stroke:#0f172a,color:#f8fafc,stroke-width:2px
    classDef consumer fill:#eff6ff,stroke:#1d4ed8,color:#1e3a8a,stroke-width:2px
    classDef pagetag fill:#f5f3ff,stroke:#6d28d9,color:#4c1d95,stroke-width:1px

    subgraph BOOK["📚 The book, after chunking & de-chrome"]
        direction LR
        C0["[0]"]:::tape
        C1["[1]"]:::tape
        C2["[2]"]:::active
        C3["[3]"]:::ahead
        C4["[4]"]:::tape
        CN["[…]"]:::tape
        C0 --- C1 --- C2 --- C3 --- C4 --- CN

        P0["p.1"]:::pagetag
        P1["p.1"]:::pagetag
        P2["p.2"]:::pagetag
        P3["p.2"]:::pagetag
        P4["p.3"]:::pagetag
        C0 -.-> P0
        C1 -.-> P1
        C2 -.-> P2
        C3 -.-> P3
        C4 -.-> P4
    end

    CUR(("🎯 cursor = i")):::cursor

    TTS["`🔊 **TTS engine**`"]:::consumer
    PRE["`🔥 **Prewarmer**
    _next N_`"]:::consumer
    READ["`🖍️ **Reader view**
    _shows page from tag_`"]:::consumer

    CUR -. points to .-> C2
    C2 -- playing --> TTS
    C3 -- warming --> PRE
    C2 -. highlight + page .-> READ
```

---

## 7. Indexing-Time Subdivision (Hidden from Consumers)

Search has a different size budget than TTS. The indexer may further subdivide an oversized paragraph into embedding sub-chunks — but the **canonical chunk row keeps the full original paragraph text**. Sub-vectors share the parent's identity; on retrieval they collapse back to one paragraph.

```mermaid
flowchart LR
    classDef chunk fill:#fefce8,stroke:#a16207,color:#713f12,stroke-width:2px,rx:6,ry:6
    classDef sub fill:#eff6ff,stroke:#1d4ed8,color:#1e3a8a,stroke-width:1px,rx:4,ry:4
    classDef row fill:#ecfdf5,stroke:#047857,color:#064e3b,stroke-width:2px,rx:4,ry:4
    classDef vec fill:#fdf4ff,stroke:#a21caf,color:#701a75,stroke-width:1px,rx:4,ry:4

    PARA["`📝 **paragraph** (oversized)
    id = i, page = p`"]:::chunk

    ROW["`💾 **canonical row**
    id = i, text = _full paragraph_`"]:::row

    SUB1["sub 1"]:::sub
    SUB2["sub 2"]:::sub
    SUB3["sub 3"]:::sub

    V1[("vec → i")]:::vec
    V2[("vec → i")]:::vec
    V3[("vec → i")]:::vec

    PARA --> ROW
    PARA --> SUB1 --> V1
    PARA --> SUB2 --> V2
    PARA --> SUB3 --> V3
```

TTS, prewarm, and highlight never see the sub-chunks. They read the canonical row.

---

## Why This Shape

| Property | Pay-off |
| --- | --- |
| **Single normalized representation** | One chunker to test, one queue to reason about. |
| **Index identity** (`passageId = String(index)`) | TTS, prewarm, highlight, and search converge on a cheap integer — no shared rich model. |
| **Page as coordinate, not identity** | UI gets "what page am I on" for free; consumers that don't care can ignore it. |
| **De-chrome before chunking, mask-based** | Footer detection is a side computation that emits a drop-set. The chunker stays pure; if the detector is off, the pipeline still works. |
| **Format extension is cheap** | A new format produces text the chunker can handle. If it has chrome, it plugs into the detector independently. |
| **Indexing sub-chunks are private** | Search can use a tighter embedding window without leaking that fact to playback. |
| **Subdivision is a safety net** | Dominant case is "paragraph in, paragraph out" — preserves semantic boundaries for natural-sounding TTS. |

---

## Out of Scope for This Model

These intentionally live elsewhere:

- 📖 Reader navigation / pagination (lives in the reader VMs).
- 🎵 Audio caching, streaming, decoding (lives below the queue).
- 🎙️ Voice selection, speed (request-level metadata, not chunk-level).
- 📚 Cross-resource boundaries in EPUB (each call chunks the current resource).
- 🧠 Embedding model choice, vector store internals (sub-chunks land there, but the model doesn't matter here).
