import { createActor } from 'xstate'
import { connectivityMachine } from '@/machines/connectivityMachine'
import { createSubscribers } from './subscribers'
import type { ConnectivityListener, ConnectivityService, ConnectivityServiceDeps } from './types'

type ConnectivityActor = ReturnType<typeof createActor<typeof connectivityMachine>>

export function createConnectivityService(deps: ConnectivityServiceDeps): ConnectivityService {
  const { source } = deps
  const subscribers = createSubscribers()

  let actor: ConnectivityActor | null = null
  let actorSub: { unsubscribe(): void } | null = null
  let onlineHandler: (() => void) | null = null
  let offlineHandler: (() => void) | null = null
  let lastOnline: boolean = source.onLine
  let started = false

  function readActorOnline(): boolean {
    if (!actor) return lastOnline
    return actor.getSnapshot().value === 'online'
  }

  return {
    isOnline() {
      return readActorOnline()
    },

    subscribe(listener: ConnectivityListener): () => void {
      subscribers.add(listener)
      return () => {
        subscribers.remove(listener)
      }
    },

    start() {
      if (started) return
      started = true

      actor = createActor(connectivityMachine)
      actor.start()

      // Reconcile machine vs. live source. The machine's initial state was
      // captured from navigator.onLine at module load; if the live source has
      // drifted since then, send the correcting event.
      const machineOnline = readActorOnline()
      if (source.onLine && !machineOnline) actor.send({ type: 'ONLINE' })
      else if (!source.onLine && machineOnline) actor.send({ type: 'OFFLINE' })
      lastOnline = readActorOnline()

      onlineHandler = () => actor?.send({ type: 'ONLINE' })
      offlineHandler = () => actor?.send({ type: 'OFFLINE' })
      source.addEventListener('online', onlineHandler)
      source.addEventListener('offline', offlineHandler)

      // xstate fires .subscribe() on every send including no-op transitions.
      // Filter to true boolean edges before fanning out.
      actorSub = actor.subscribe(() => {
        const next = readActorOnline()
        if (next === lastOnline) return
        lastOnline = next
        subscribers.notify(next)
      })
    },

    stop() {
      if (!started) return
      started = false

      if (actorSub) actorSub.unsubscribe()
      actorSub = null

      if (onlineHandler) source.removeEventListener('online', onlineHandler)
      if (offlineHandler) source.removeEventListener('offline', offlineHandler)
      onlineHandler = null
      offlineHandler = null

      if (actor) actor.stop()
      actor = null
      // lastOnline preserved as last-known value for isOnline() reads.
    }
  }
}
