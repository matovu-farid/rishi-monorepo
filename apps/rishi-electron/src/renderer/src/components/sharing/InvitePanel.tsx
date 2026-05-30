import React, { useEffect, useState } from 'react'

export type InviteUser = { userId: string; email: string; displayName: string; avatarUrl?: string }

export type InvitePanelProps = {
  joinUrl: string
  onSearchUsers: (q: string) => Promise<InviteUser[]>
  onInviteUser: (u: InviteUser) => void
}

export function InvitePanel({
  joinUrl, onSearchUsers, onInviteUser
}: InvitePanelProps): React.JSX.Element {
  const [query, setQuery] = useState('')
  const [results, setResults] = useState<InviteUser[]>([])
  const [copied, setCopied] = useState(false)

  useEffect(() => {
    if (!query) { setResults([]); return }
    const handle = setTimeout(async () => {
      try { setResults(await onSearchUsers(query)) } catch { setResults([]) }
    }, 250)
    return () => clearTimeout(handle)
  }, [query, onSearchUsers])

  return (
    <div className="space-y-4">
      <div className="space-y-2">
        <label htmlFor="invite-link" className="text-sm font-medium">Invite link</label>
        <div className="flex gap-2">
          <input id="invite-link" readOnly value={joinUrl} className="flex-1 border rounded px-2 py-1" />
          <button
            type="button"
            onClick={async () => {
              await navigator.clipboard.writeText(joinUrl)
              setCopied(true)
              setTimeout(() => setCopied(false), 1500)
            }}
            className="px-3 py-1 border rounded"
          >
            {copied ? 'Copied' : 'Copy'}
          </button>
        </div>
      </div>
      <div className="space-y-2">
        <label htmlFor="invite-email" className="text-sm font-medium">Invite by email</label>
        <input
          id="invite-email"
          aria-label="email"
          value={query}
          onChange={(e) => setQuery(e.target.value)}
          placeholder="name@example.com"
          className="w-full border rounded px-2 py-1"
        />
        <ul>
          {results.map((u) => (
            <li key={u.userId} className="flex items-center justify-between py-1">
              <span>{u.displayName} <span className="text-muted-foreground">({u.email})</span></span>
              <button type="button" className="text-sm underline" onClick={() => onInviteUser(u)}>Invite</button>
            </li>
          ))}
        </ul>
      </div>
    </div>
  )
}
