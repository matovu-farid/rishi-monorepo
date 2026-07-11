/**
 * Shared realtime-agent prompt template + section helpers.
 *
 * The electron `apps/rishi-electron/src/renderer/src/modules/buildRealtimeAgent.ts`
 * combines two concerns:
 *   1. Pure string rendering of the system prompt (INSTRUCTIONS_TEMPLATE + the
 *      render*Section helpers).
 *   2. Construction of a `RealtimeAgent` instance with tools wired up.
 *
 * Concern 1 must be identical on every platform (mobile, electron) — that's
 * what this file exposes. Concern 2 stays platform-specific because the
 * `@openai/agents/realtime` SDK type, the RAG service implementation, and
 * the page-capture mechanism all differ between Electron and React Native.
 *
 * The platform-specific `buildRealtimeAgent.ts` files SHOULD import
 * `renderRealtimeInstructions` from here and pass the result to whatever
 * `RealtimeAgent`-like type their SDK provides.
 */
import { LANGUAGE_LABELS, isAllowedLanguage, DEFAULT_LANGUAGE } from '../lib/languages';
export function renderOutlineSection(outline) {
    if (!outline)
        return '';
    const authorLine = outline.author ? `**Author:** ${outline.author}\n` : '';
    const chapterLines = outline.chapters.length > 0
        ? `**Chapters:**\n${outline.chapters.map((c) => `- ${c}`).join('\n')}\n`
        : '';
    return `## Book Outline
**Title:** ${outline.title}
${authorLine}${chapterLines}
Use this outline to orient the user across the book. If they ask about a specific chapter that isn't on their current page, you may use the bookContext tool to retrieve relevant passages from that chapter.

`;
}
export function renderActiveParagraphSection(activeParagraphText) {
    if (!activeParagraphText)
        return '';
    return `## What the user just heard
The user was just listening to this passage being read aloud:
"""
${activeParagraphText}
"""
This is part of the current page above. If they say "this", "that", "what you just read", or otherwise refer back to what they heard, they mean this passage.

`;
}
export function renderVisualSection(summary) {
    if (!summary)
        return '';
    const parts = [];
    if (summary.equations > 0)
        parts.push(`${summary.equations} ${summary.equations === 1 ? 'equation' : 'equations'}`);
    if (summary.figures > 0)
        parts.push(`${summary.figures} ${summary.figures === 1 ? 'figure' : 'figures'}`);
    if (summary.images > 0)
        parts.push(`${summary.images} ${summary.images === 1 ? 'image' : 'images'}`);
    const description = parts.length > 0 ? parts.join(' and ') : 'no visual content (text-only page)';
    return `## Visual context
The current page contains ${description}.

You have a tool \`inspectCurrentPage({ detail: 'low' | 'high' })\` that returns a screenshot of what the user is looking at right now. Use \`detail: 'low'\` (default) for general layout questions. Use \`detail: 'high'\` only if you need to read small text inside the image (equations, captions, axis labels). Do not call it on every turn — only when the user's question requires visual context.

`;
}
export function renderLanguageSection(language) {
    const code = isAllowedLanguage(language) ? language : DEFAULT_LANGUAGE;
    const label = LANGUAGE_LABELS[code];
    return `## Language
Always respond in ${label} regardless of the user's accent or pronunciation. Treat all input as ${label} unless the user explicitly switches mid-conversation.

`;
}
/**
 * The canonical INSTRUCTIONS template. Both Electron and React Native MUST
 * use this string verbatim — that is the entire point of porting it to
 * shared. If the prompt changes here, both clients see the new behaviour
 * immediately.
 */
export function renderRealtimeInstructions(input) {
    const { pageText, language, outline, activeParagraphText, visualSummary } = input;
    return `## Role
You are the user's personal teacher for this book — a knowledgeable, patient tutor guiding them through it. Teach, don't just answer: explain the book's concepts clearly, give guidance and instruction, connect ideas across chapters, and build the user's understanding step by step. Anticipate where they may get stuck, scaffold from what they already know, and ground every explanation in this specific book.

${renderLanguageSection(language)}${renderOutlineSection(outline)}${renderVisualSection(visualSummary)}## Current Page Content
"""
${pageText || '(No page text available)'}
"""
If the question is answerable from this page, answer directly. Use the bookContext tool only for content outside this page.

${renderActiveParagraphSection(activeParagraphText)}

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
- Keep responses concise unless depth is requested.`;
}
/**
 * Tool spec for `bookContext`. Shape-only — the OpenAI Agents SDK on each
 * platform turns this into its own runtime `tool({...})` wrapper. Exposed
 * so non-Agents-SDK clients (e.g. raw data-channel JSON in mobile's
 * `lib/realtime/types.ts`) can read the same description.
 */
export const BOOK_CONTEXT_TOOL_SPEC = {
    name: 'bookContext',
    description: 'Retrieve information from OTHER parts of the book beyond the current page. Only use this when the user asks about content NOT visible on their current page. Do NOT call this tool if the answer is already in the current page content provided in your instructions.',
    parameters: {
        type: 'object',
        properties: {
            queryText: { type: 'string' }
        },
        required: ['queryText']
    }
};
export const END_CONVERSATION_TOOL_SPEC = {
    name: 'endConversation',
    description: 'End the conversation with the user.',
    parameters: {
        type: 'object',
        properties: {
            reason: { type: 'string' }
        },
        required: ['reason']
    }
};
export const INSPECT_CURRENT_PAGE_TOOL_SPEC = {
    name: 'inspectCurrentPage',
    description: "Capture a screenshot of the page the user is currently looking at. Use 'low' detail by default; use 'high' only when you need to read small text inside the image such as equations, captions, or axis labels.",
    parameters: {
        type: 'object',
        properties: {
            detail: { type: 'string', enum: ['low', 'high'] }
        },
        required: ['detail']
    }
};
