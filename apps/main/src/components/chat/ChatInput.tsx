import { useState, useCallback } from 'react';
import { Mic, SendHorizontal } from 'lucide-react';
import { useVoiceInput } from '@/hooks/useVoiceInput';

interface ChatInputProps {
  onSend: (text: string) => void;
  disabled: boolean;
}

export function ChatInput({ onSend, disabled }: ChatInputProps) {
  const [value, setValue] = useState('');
  const { isRecording, duration, error: voiceError, startRecording, stopRecording } = useVoiceInput();

  const handleSend = useCallback(() => {
    const trimmed = value.trim();
    if (!trimmed) return;
    onSend(trimmed);
    setValue('');
  }, [value, onSend]);

  const handleKeyDown = (e: React.KeyboardEvent<HTMLInputElement>) => {
    if (e.key === 'Enter' && !e.shiftKey) {
      e.preventDefault();
      handleSend();
    }
    if (e.key === 'Escape') {
      setValue('');
    }
  };

  const handleVoiceClick = async () => {
    if (isRecording) {
      try {
        const transcript = await stopRecording();
        if (transcript) {
          setValue(transcript);
        }
      } catch {
        // Error handled in hook
      }
    } else {
      await startRecording();
    }
  };

  return (
    <div className="flex flex-col gap-1">
      {voiceError && (
        <p className="text-xs text-destructive px-1">{voiceError}</p>
      )}
      <div className="flex items-center gap-1">
        <input
          type="text"
          className="flex-1 h-9 rounded-md border border-input bg-background px-3 py-1 text-sm placeholder:text-muted-foreground focus-visible:outline-none focus-visible:ring-1 focus-visible:ring-ring disabled:cursor-not-allowed disabled:opacity-50"
          placeholder={isRecording ? `Recording... ${duration}s` : 'Ask about this book...'}
          value={value}
          onChange={(e) => setValue(e.target.value)}
          onKeyDown={handleKeyDown}
          disabled={disabled}
        />
        <button
          type="button"
          className={`h-9 w-9 inline-flex items-center justify-center rounded-md text-sm font-medium transition-colors focus-visible:outline-none focus-visible:ring-1 focus-visible:ring-ring ${
            isRecording
              ? 'animate-pulse bg-destructive/20 text-destructive'
              : 'hover:bg-accent hover:text-accent-foreground'
          }`}
          onClick={handleVoiceClick}
          disabled={disabled}
          aria-label={isRecording ? 'Stop recording' : 'Start voice recording'}
        >
          <Mic size={16} />
        </button>
        <button
          type="button"
          className="h-9 w-9 inline-flex items-center justify-center rounded-md bg-primary text-primary-foreground text-sm font-medium transition-colors hover:bg-primary/90 focus-visible:outline-none focus-visible:ring-1 focus-visible:ring-ring disabled:pointer-events-none disabled:opacity-50"
          onClick={handleSend}
          disabled={disabled || (!value.trim() && !isRecording)}
          aria-label="Send message"
        >
          <SendHorizontal size={16} />
        </button>
      </div>
    </div>
  );
}
