import React from 'react'
import { ParticipantTile } from './ParticipantTile'
import { ApprovalQueueItem } from './ApprovalQueueItem'
import { InvitePanel, type InviteUser } from './InvitePanel'
import { FileTransferRow } from './FileTransferRow'

export type SessionPanelParticipant = {
  userId: string
  profile: { displayName: string; avatarUrl?: string }
  joinedAt: number
  hasBookFile: boolean
  micState: 'unmuted' | 'self-muted' | 'host-muted'
  connectionState: 'connected' | 'reconnecting'
}

export type SessionPanelProps = {
  role: 'host' | 'viewer'
  selfUserId: string
  sharerId: string
  participants: SessionPanelParticipant[]
  pendingJoiners: Array<{ userId: string; profile: { displayName: string; avatarUrl?: string } }>
  joinUrl: string
  fileTransfers: Array<{ peerName: string; sent: number; total: number; failed?: boolean }>
  onSearchUsers: (q: string) => Promise<InviteUser[]>
  onInviteUser: (u: InviteUser) => void
  onApprove: (userId: string) => void
  onReject: (userId: string) => void
  onMute: (userId: string) => void
  onUnmute: (userId: string) => void
  onPassSharer: (userId: string) => void
  onKick: (userId: string) => void
}

/**
 * Build an `onSearchUsers` callback that hits the Worker's
 * `POST /v1/users/search` route. Exported as a helper so tests can
 * substitute a fake. The host renderer wires this into <SessionPanel>.
 */
export async function searchUsersViaWorker(
  q: string,
  workerBaseUrl: string,
  bearer: string
): Promise<InviteUser[]> {
  const res = await fetch(`${workerBaseUrl}/v1/users/search`, {
    method: 'POST',
    headers: {
      'content-type': 'application/json',
      authorization: `Bearer ${bearer}`
    },
    body: JSON.stringify({ q })
  })
  if (!res.ok) return []
  const body = (await res.json().catch(() => ({}))) as { users?: InviteUser[] }
  return body.users ?? []
}

export function SessionPanel(p: SessionPanelProps): React.JSX.Element {
  return (
    <aside aria-label="Shared reading session" className="w-72 border-l bg-background p-3 space-y-4">
      <section>
        <h3 className="text-xs uppercase font-semibold mb-2">Participants</h3>
        <ul>
          {p.participants.map((part) => (
            <li key={part.userId}>
              <ParticipantTile
                userId={part.userId}
                displayName={part.profile.displayName}
                avatarUrl={part.profile.avatarUrl}
                isSharer={p.sharerId === part.userId}
                isHost={p.selfUserId === part.userId && p.role === 'host'}
                isSelf={p.selfUserId === part.userId}
                micState={part.micState}
                isHostMenuVisible={p.role === 'host' && p.selfUserId !== part.userId}
                onMute={() => p.onMute(part.userId)}
                onUnmute={() => p.onUnmute(part.userId)}
                onPassSharer={() => p.onPassSharer(part.userId)}
                onKick={() => p.onKick(part.userId)}
              />
            </li>
          ))}
        </ul>
      </section>

      {p.role === 'host' && p.pendingJoiners.length > 0 && (
        <section>
          <h3 className="text-xs uppercase font-semibold mb-2">Pending</h3>
          <ul>
            {p.pendingJoiners.map((j) => (
              <li key={j.userId}>
                <ApprovalQueueItem
                  displayName={j.profile.displayName}
                  onApprove={() => p.onApprove(j.userId)}
                  onReject={() => p.onReject(j.userId)}
                />
              </li>
            ))}
          </ul>
        </section>
      )}

      <section>
        <h3 className="text-xs uppercase font-semibold mb-2">Invite</h3>
        <InvitePanel joinUrl={p.joinUrl} onSearchUsers={p.onSearchUsers} onInviteUser={p.onInviteUser} />
      </section>

      {p.fileTransfers.length > 0 && (
        <section>
          <h3 className="text-xs uppercase font-semibold mb-2">Transfers</h3>
          {p.fileTransfers.map((t, i) => <FileTransferRow key={i} {...t} />)}
        </section>
      )}
    </aside>
  )
}
