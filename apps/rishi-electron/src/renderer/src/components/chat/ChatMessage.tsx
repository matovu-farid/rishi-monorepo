import ReactMarkdown from 'react-markdown'
import remarkGfm from 'remark-gfm'
import rehypeSanitize, { defaultSchema } from 'rehype-sanitize'
import { SourceChip } from './SourceChip'
import type { Message } from '@/types/conversation'

interface ChatMessageProps {
  message: Message
  onSourceNavigate: (pageNumber: number) => void
}

// Tight sanitisation schema. Inherits hast-util-sanitize defaults (which
// strip <script>, on* handlers, javascript: URLs etc.) and additionally
// permits the `className` attribute on code/pre so syntax styling hooks
// emitted by remark-gfm (e.g. `language-ts`) survive sanitisation.
// Why explicit: model output is untrusted; an HTML injection in an
// assistant reply must not be able to run code in the renderer process.
const sanitizeSchema = {
  ...defaultSchema,
  attributes: {
    ...defaultSchema.attributes,
    code: [...(defaultSchema.attributes?.code ?? []), 'className'],
    pre: [...(defaultSchema.attributes?.pre ?? []), 'className']
  }
}

const REMARK_PLUGINS = [remarkGfm]
const REHYPE_PLUGINS = [[rehypeSanitize, sanitizeSchema]] as const

// Prose-style class strings kept on the bubble so markdown elements
// (lists, headings, code blocks, tables) inherit consistent spacing/typography
// without blowing up the existing chat-bubble layout.
const MARKDOWN_PROSE_CLASSES = [
  'text-sm',
  'leading-relaxed',
  'break-words',
  '[&>*:first-child]:mt-0',
  '[&>*:last-child]:mb-0',
  '[&_p]:my-1',
  '[&_ul]:list-disc [&_ul]:pl-5 [&_ul]:my-1',
  '[&_ol]:list-decimal [&_ol]:pl-5 [&_ol]:my-1',
  '[&_li]:my-0.5',
  '[&_h1]:text-base [&_h1]:font-semibold [&_h1]:mt-2 [&_h1]:mb-1',
  '[&_h2]:text-base [&_h2]:font-semibold [&_h2]:mt-2 [&_h2]:mb-1',
  '[&_h3]:text-sm [&_h3]:font-semibold [&_h3]:mt-2 [&_h3]:mb-1',
  '[&_code]:font-mono [&_code]:text-[0.85em] [&_code]:px-1 [&_code]:py-0.5 [&_code]:rounded',
  '[&_code]:bg-black/10 dark:[&_code]:bg-white/10',
  '[&_pre]:bg-black/10 dark:[&_pre]:bg-white/10 [&_pre]:p-2 [&_pre]:rounded [&_pre]:overflow-x-auto [&_pre]:my-1',
  '[&_pre_code]:bg-transparent [&_pre_code]:p-0',
  '[&_a]:underline [&_a]:underline-offset-2',
  '[&_blockquote]:border-l-2 [&_blockquote]:pl-2 [&_blockquote]:opacity-80 [&_blockquote]:my-1'
].join(' ')

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
        <div className={MARKDOWN_PROSE_CLASSES}>
          <ReactMarkdown
            remarkPlugins={REMARK_PLUGINS}
            // rehype-sanitize strips <script>, event handlers, and unsafe URLs
            // from model output. Non-negotiable: assistant text is untrusted.
            rehypePlugins={REHYPE_PLUGINS as never}
            // Force external links to open safely; the sanitize schema already
            // permits href but we want the navigation behaviour locked down.
            components={{
              a: ({ children, ...props }) => (
                <a {...props} target="_blank" rel="noopener noreferrer">
                  {children}
                </a>
              )
            }}
          >
            {message.content}
          </ReactMarkdown>
        </div>

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
