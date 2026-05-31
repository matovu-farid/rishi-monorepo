import { useMachine } from '@xstate/react'
import { useEffect, useMemo } from 'react'
import { fromPromise } from 'xstate'
import { sessionMachine } from '@/machines/sessionMachine'
import type { CreateSessionOutput, Me, RedeemOutput } from '@/machines/sessionMachine'
import { registerSessionMachineActor } from '@/testing/sharing-test-hooks'

type BookContextT = {
  bookId: string
  contentHash: string
  format: 'epub' | 'pdf'
}

export function useSessionMachine() {
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
