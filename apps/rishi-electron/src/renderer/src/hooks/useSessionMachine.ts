import { useMachine } from '@xstate/react'
import {
  createContext,
  createElement,
  useContext,
  useEffect,
  useMemo,
  type PropsWithChildren,
  type ReactElement
} from 'react'
import { fromPromise } from 'xstate'
import { sessionMachine } from '@/machines/sessionMachine'
import type { CreateSessionOutput, Me, RedeemOutput } from '@/machines/sessionMachine'
import { registerSessionMachineActor } from '@/testing/sharing-test-hooks'

type BookContextT = {
  bookId: string
  contentHash: string
  format: 'epub' | 'pdf'
}

/**
 * Internal: spawn a single sessionMachine actor and wire it to the test-hook
 * registry. Exported only via the hook + provider — there is no production
 * code path that should call this directly.
 */
function useSessionMachineInternal() {
  const machine = useMemo(
    () =>
      sessionMachine.provide({
        actors: {
          createSessionOnDO: fromPromise<
            CreateSessionOutput,
            { me: Me; bookContext: BookContextT; requiresApproval: boolean }
          >(async ({ input }) => {
            const { workerBaseUrl } = await window.electron.sharing.getConfig()
            const res = await fetch(`${workerBaseUrl}/v1/sessions`, {
              method: 'POST',
              headers: {
                'content-type': 'application/json',
                authorization: `Bearer ${input.me.authToken}`
              },
              body: JSON.stringify({
                bookContext: input.bookContext,
                requiresApproval: input.requiresApproval
              })
            })
            if (!res.ok) throw new Error(`create_failed_${res.status}`)
            return (await res.json()) as CreateSessionOutput
          }),
          redeemJoinToken: fromPromise<
            RedeemOutput,
            { me: Me; sessionId: string; joinToken: string }
          >(async ({ input }) => {
            const { workerBaseUrl } = await window.electron.sharing.getConfig()
            const res = await fetch(
              `${workerBaseUrl}/v1/sessions/${encodeURIComponent(input.sessionId)}/redeem`,
              {
                method: 'POST',
                headers: {
                  'content-type': 'application/json',
                  authorization: `Bearer ${input.me.authToken}`
                },
                body: JSON.stringify({ joinToken: input.joinToken })
              }
            )
            if (!res.ok) {
              const body = (await res.json().catch(() => ({}))) as { code?: string }
              throw new Error(body.code ?? `redeem_failed_${res.status}`)
            }
            return (await res.json()) as RedeemOutput
          })
        }
      }),
    []
  )
  const [state, send, actorRef] = useMachine(machine)

  // Register actor with the E2E test-hook registry. The hook never has more
  // than one live session at a time, and the registry is a single-slot
  // singleton; unregister on unmount so we never expose a stale snapshot.
  useEffect(() => {
    registerSessionMachineActor(actorRef as unknown as Parameters<typeof registerSessionMachineActor>[0])
    return () => registerSessionMachineActor(null)
  }, [actorRef])

  useEffect(() => {
    const unsub = window.electron?.sharing?.onDeepLink?.((p) => {
      void (async () => {
        const { jwt } = await window.electron.sharing.getSigningJwt()
        send({
          type: 'ACCEPT_INVITE',
          me: { userId: 'self', displayName: 'self', authToken: jwt },
          sessionId: '',
          joinToken: p.joinToken
        })
      })()
    })
    return unsub
  }, [send])

  return { state, send, actorRef }
}

type SessionMachineHookValue = ReturnType<typeof useSessionMachineInternal>

const SessionMachineContext = createContext<SessionMachineHookValue | null>(null)

/**
 * App-shell provider for the session machine. Mount once near the React root
 * so that every consumer (`SessionEntryButton`, `SharingSessionOverlay`, etc.)
 * shares ONE actor instance — host actions and the overlay's view of state
 * must reference the same xstate actor or the overlay will render an empty
 * stub while the live actor is held by a different component.
 *
 * Outside the provider (unit tests calling `useSessionMachine` directly) the
 * hook falls back to spawning its own actor, keeping the existing test
 * surface intact.
 */
export function SessionMachineProvider({ children }: PropsWithChildren): ReactElement {
  const value = useSessionMachineInternal()
  return createElement(SessionMachineContext.Provider, { value }, children)
}

/**
 * Access the session machine. Prefers the value from the nearest
 * `SessionMachineProvider`; if no provider is mounted, spawns a local actor
 * so direct unit tests of components that depend on this hook still work.
 *
 * Implementation note: we deliberately read the context with a default
 * sentinel and only call the local actor when the sentinel is observed. The
 * provider/no-provider decision is stable for the lifetime of any consumer
 * subtree, so the conditional hook call doesn't violate the rules of hooks
 * in practice (callers don't switch between mounted-in-provider and
 * mounted-without-provider mid-lifetime).
 */
export function useSessionMachine(): SessionMachineHookValue {
  const ctx = useContext(SessionMachineContext)
  if (ctx) return ctx
  // eslint-disable-next-line react-hooks/rules-of-hooks
  return useSessionMachineInternal()
}
