import type React from 'react'
export type ParticipantTileProps = {
  userId: string
  displayName: string
  avatarUrl?: string
  isSharer: boolean
  isHost: boolean
  isSelf: boolean
  micState: 'unmuted' | 'self-muted' | 'host-muted'
  isHostMenuVisible: boolean
  onMute?: () => void
  onUnmute?: () => void
  onPassSharer?: () => void
  onKick?: () => void
}
export function ParticipantTile(p: ParticipantTileProps): React.JSX.Element {
  return (
    <div className="flex items-center gap-2 py-1">
      <div className="h-8 w-8 rounded-full bg-muted flex items-center justify-center text-xs">
        {p.avatarUrl ? (
          <img src={p.avatarUrl} alt="" className="h-8 w-8 rounded-full" />
        ) : (
          p.displayName.slice(0, 1)
        )}
      </div>
      <div className="flex-1 truncate">
        <div className="text-sm">
          {p.displayName}
          {p.isSelf ? ' (you)' : ''}
        </div>
        <div className="text-xs text-muted-foreground">
          {p.isHost ? 'Host · ' : ''}
          {p.isSharer ? 'Sharer · ' : ''}
          {p.micState}
        </div>
      </div>
      {p.isHostMenuVisible ? (
        <div className="flex gap-1 text-xs">
          {p.micState === 'host-muted' ? (
            <button onClick={p.onUnmute}>Unmute</button>
          ) : (
            <button onClick={p.onMute}>Mute</button>
          )}
          <button onClick={p.onPassSharer}>Pass</button>
          <button onClick={p.onKick}>Kick</button>
        </div>
      ) : null}
    </div>
  )
}
