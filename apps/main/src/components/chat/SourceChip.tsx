import {
  Tooltip,
  TooltipTrigger,
  TooltipContent,
} from '@components/components/ui/tooltip';
import type { SourceChunk } from '@/types/conversation';

interface SourceChipProps {
  chunk: SourceChunk;
  onNavigate: (pageNumber: number) => void;
}

export function SourceChip({ chunk, onNavigate }: SourceChipProps) {
  const label = chunk.chapter
    ? `Ch. ${chunk.chapter.length > 17 ? chunk.chapter.substring(0, 17) + '...' : chunk.chapter}`
    : `p. ${chunk.pageNumber}`;

  const tooltipText = [
    chunk.chapter ? `Chapter: ${chunk.chapter}` : null,
    chunk.text.substring(0, 100) + (chunk.text.length > 100 ? '...' : ''),
  ]
    .filter(Boolean)
    .join('\n');

  return (
    <Tooltip>
      <TooltipTrigger asChild>
        <button
          type="button"
          className="inline-flex items-center rounded-full border border-border px-2.5 py-0.5 text-xs font-medium cursor-pointer hover:bg-accent transition-colors"
          onClick={() => onNavigate(chunk.pageNumber)}
        >
          {label}
        </button>
      </TooltipTrigger>
      <TooltipContent className="max-w-[250px] whitespace-pre-wrap">
        {tooltipText}
      </TooltipContent>
    </Tooltip>
  );
}
