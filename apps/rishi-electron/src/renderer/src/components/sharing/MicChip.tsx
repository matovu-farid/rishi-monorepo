import React from 'react'
export type MicChipProps = {
  micState: 'unmuted' | 'self-muted' | 'host-muted'
  onToggle: () => void
}
export function MicChip({ micState, onToggle }: MicChipProps): React.JSX.Element {
  const disabled = micState === 'host-muted'
  return (
    <button
      type="button"
      onClick={onToggle}
      disabled={disabled}
      aria-pressed={micState !== 'unmuted'}
      className={`px-2 py-1 rounded text-xs border ${micState === 'unmuted' ? 'bg-primary text-primary-foreground' : 'bg-muted'}`}
    >
      {micState === 'unmuted' ? 'Mic on' : micState === 'self-muted' ? 'Mic muted' : 'Muted by host'}
    </button>
  )
}
