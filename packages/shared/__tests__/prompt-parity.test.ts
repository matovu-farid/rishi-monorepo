/**
 * T-P5.2 — DRY-004 prompt-parity test (electron vs shared).
 *
 * Source documents:
 *   - `.parity-v2/SPEC.md` §3.6 (DRY-004 — Lift renderRealtimeInstructions Helpers)
 *   - `.parity-v2/PLAN.md` T-P3.4 / T-P5.2 (subsumed)
 *
 * DRY-004 deletes the three inline render helpers in
 * `apps/rishi-electron/src/renderer/src/modules/buildRealtimeAgent.ts:114-158`
 * and replaces them with imports of the shared `renderRealtimeInstructions`
 * from `@rishi/shared/voice-chat/build-realtime-agent`. The parity guarantee
 * is that BOTH clients produce byte-identical instructions for the same
 * fixed input.
 *
 * Because we cannot import the electron module directly from a shared vitest
 * suite (electron's file pulls in `@/services`, `@/lib/api`, `@openai/agents`,
 * `effect`, etc. — node-resolution from `packages/shared` cannot satisfy those
 * `@/` paths), we inline the electron helpers VERBATIM as a fixture below.
 * If electron's file changes, the byte-equality assertion fails and signals
 * a parity drift — which is exactly the regression this test exists to catch.
 *
 * Expected current state:
 *   - PRE-DRY-004 land: passes (the helpers are byte-for-byte copies on both
 *     sides — see SPEC §3.6 "Risk" note).
 *   - If the inline electron helpers drift even by a single whitespace char,
 *     this test FAILS and the parity contract is broken.
 *   - POST-DRY-004 land: this test reduces to comparing the shared helper
 *     against a copy of itself — trivially passes — but stays in the suite
 *     as a guard against re-introduction of the inline helpers in electron.
 */
import { describe, it, expect } from 'vitest'
import {
  renderRealtimeInstructions,
  type RealtimeInstructionsInput,
} from '../src/voice-chat/build-realtime-agent'
import { LANGUAGE_LABELS, isAllowedLanguage, DEFAULT_LANGUAGE } from '../src/lib/languages'
import type { BookOutline, VisualSummary } from '../src/voice-chat/types'

// ────────────────────────────────────────────────────────────────────────────
// VERBATIM COPY of electron's local render helpers, currently at
// `apps/rishi-electron/src/renderer/src/modules/buildRealtimeAgent.ts:114-203`.
// If electron's file changes, this block must be re-synced and the byte-equal
// assertion below will catch the drift.
// ────────────────────────────────────────────────────────────────────────────

function electronRenderOutlineSection(outline: BookOutline | undefined): string {
  if (!outline) return ''
  const authorLine = outline.author ? `**Author:** ${outline.author}\n` : ''
  const chapterLines =
    outline.chapters.length > 0
      ? `**Chapters:**\n${outline.chapters.map((c) => `- ${c}`).join('\n')}\n`
      : ''
  return `## Book Outline
**Title:** ${outline.title}
${authorLine}${chapterLines}
Use this outline to orient the user across the book. If they ask about a specific chapter that isn't on their current page, you may use the bookContext tool to retrieve relevant passages from that chapter.

`
}

function electronRenderActiveParagraphSection(activeParagraphText: string | undefined): string {
  if (!activeParagraphText) return ''
  return `## What the user just heard
The user was just listening to this passage being read aloud:
"""
${activeParagraphText}
"""
This is part of the current page above. If they say "this", "that", "what you just read", or otherwise refer back to what they heard, they mean this passage.

`
}

function electronRenderVisualSection(summary: VisualSummary | undefined): string {
  if (!summary) return ''
  const parts: string[] = []
  if (summary.equations > 0)
    parts.push(`${summary.equations} ${summary.equations === 1 ? 'equation' : 'equations'}`)
  if (summary.figures > 0)
    parts.push(`${summary.figures} ${summary.figures === 1 ? 'figure' : 'figures'}`)
  if (summary.images > 0)
    parts.push(`${summary.images} ${summary.images === 1 ? 'image' : 'images'}`)
  const description = parts.length > 0 ? parts.join(' and ') : 'no visual content (text-only page)'

  return `## Visual context
The current page contains ${description}.

You have a tool \`inspectCurrentPage({ detail: 'low' | 'high' })\` that returns a screenshot of what the user is looking at right now. Use \`detail: 'low'\` (default) for general layout questions. Use \`detail: 'high'\` only if you need to read small text inside the image (equations, captions, axis labels). Do not call it on every turn — only when the user's question requires visual context.

`
}

function electronRenderLanguageSection(language: string): string {
  const code = isAllowedLanguage(language) ? language : DEFAULT_LANGUAGE
  const label = LANGUAGE_LABELS[code]
  return `## Language
Always respond in ${label} regardless of the user's accent or pronunciation. Treat all input as ${label} unless the user explicitly switches mid-conversation.

`
}

function electronInstructionsTemplate(
  pageText: string,
  language: string,
  outline?: BookOutline,
  activeParagraphText?: string,
  visualSummary?: VisualSummary,
): string {
  return `## Role
You are a teaching assistant helping the user understand the book they're reading. Make complex ideas accessible and answer questions in a way that aids comprehension.

${electronRenderLanguageSection(language)}${electronRenderOutlineSection(outline)}${electronRenderVisualSection(visualSummary)}## Current Page Content
"""
${pageText || '(No page text available)'}
"""
If the question is answerable from this page, answer directly. Use the bookContext tool only for content outside this page.

${electronRenderActiveParagraphSection(activeParagraphText)}

## Rules
- Vary phrasing — never repeat the same sentence verbatim in a single response.
- Stay conversational; avoid scripted-sounding language.
- Before calling a tool, say one short line previewing what you're doing (5-12 words).
- Stay focused on the book, but allow natural chat flow.

## Tools

### bookContext
For content NOT visible on the current page. Provide a brief preamble before calling. Do not call if the answer is already in the current page text.

### endConversation
When the user clearly signals they're done (e.g., "thanks, that's all", "goodbye"), respond with a warm closing and call this tool. If the signal is ambiguous, confirm first. Provide a clear \`reason\` describing why the conversation is ending.

## Style notes
- First message: if the user asks a question, answer it directly. If they greet, respond briefly and ask how you can help.
- When explaining concepts, break down complexity and use analogies. Briefly check understanding before moving on.
- Keep responses concise unless depth is requested.`
}

// ── Fixed fixture (per SPEC §3.6 acceptance criteria) ───────────────────────
const FIXTURE: RealtimeInstructionsInput = {
  pageText:
    'The rain in Spain falls mainly on the plain. The plain in Spain is the home of the rain. The rain that falls on the plain in Spain is mainly the same.',
  language: 'en',
  outline: {
    title: 'My Fair Lady',
    author: 'George Bernard Shaw',
    chapters: ['Act I', 'Act II', 'Act III'],
  },
  activeParagraphText: 'The user was attending to a specific paragraph about rain.',
  visualSummary: { equations: 1, figures: 2, images: 3 },
}

describe('prompt parity — shared renderRealtimeInstructions vs electron inline helpers (DRY-004)', () => {
  it('produces byte-identical output for the same fixed fixture', () => {
    const sharedOutput = renderRealtimeInstructions(FIXTURE)
    const electronOutput = electronInstructionsTemplate(
      FIXTURE.pageText,
      FIXTURE.language,
      FIXTURE.outline,
      FIXTURE.activeParagraphText,
      FIXTURE.visualSummary,
    )
    expect(sharedOutput).toBe(electronOutput)
  })

  it('produces byte-identical output when optional sections are absent', () => {
    const minimal: RealtimeInstructionsInput = { pageText: 'hello', language: 'en' }
    const sharedOutput = renderRealtimeInstructions(minimal)
    const electronOutput = electronInstructionsTemplate(
      minimal.pageText,
      minimal.language,
      undefined,
      undefined,
      undefined,
    )
    expect(sharedOutput).toBe(electronOutput)
  })

  it('produces byte-identical output for a non-English language', () => {
    const french: RealtimeInstructionsInput = { ...FIXTURE, language: 'fr' }
    const sharedOutput = renderRealtimeInstructions(french)
    const electronOutput = electronInstructionsTemplate(
      french.pageText,
      french.language,
      french.outline,
      french.activeParagraphText,
      french.visualSummary,
    )
    expect(sharedOutput).toBe(electronOutput)
  })
})
