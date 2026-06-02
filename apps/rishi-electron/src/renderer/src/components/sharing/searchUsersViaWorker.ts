import type { InviteUser } from './InvitePanel'

/**
 * Build an `onSearchUsers` callback that hits the Worker's
 * `POST /v1/users/search` route. Exported as a helper so tests can
 * substitute a fake. The host renderer wires this into <SessionPanel>.
 *
 * Lives in its own module (rather than alongside SessionPanel) so the
 * component file only exports components — keeps Fast Refresh happy
 * (`react-refresh/only-export-components`).
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
